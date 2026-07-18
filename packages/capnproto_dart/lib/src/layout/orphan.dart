// Orphan/Adopt: zero-copy pointer ownership transfer within one message.
//
// An Orphan is a detached Cap'n Proto object — its bytes remain exactly where
// they were allocated in the arena that built them, but nothing currently
// points to it. Disowning a pointer field zeroes that field and hands back
// an Orphan referencing the same, unmoved content; adopting an Orphan into a
// different pointer field (or the message root) writes a pointer to that
// same location. Neither operation ever touches the content's own bytes —
// only the pointer word(s) at the disown/adopt sites change.
//
// Scoped to moves within a single arena (one MessageBuilder). Cap'n Proto's
// pointers are segment-relative within one arena's segment table, so a true
// zero-copy move into an unrelated arena isn't representable without
// importing every segment the content transitively reaches (nested far
// pointers can lead anywhere in the source arena) and rewriting their
// segment IDs — at that point it's a different, riskier flavor of the deep
// copy this feature exists to avoid. Use message_copy.dart's
// copyMessageRootToBuilder/copyAnyPointerToNewMessage to move content across
// independent messages.
//
// Capability pointers can't be orphaned: a capability index is only
// meaningful together with its message's capability table, which this
// serialization-only runtime has no concept of.

import '../arena/arena_builder.dart';
import '../arena/arena_reader.dart';
import '../arena/segment_builder.dart';
import '../arena/segment_reader.dart';
import '../exception/decode_exception.dart';
import '../wire/pointer.dart';
import '../wire/wire_helpers.dart';

/// A detached Cap'n Proto object. See the file-level doc comment for the
/// zero-copy/same-arena contract. Created by [StructBuilder.disownPointerField];
/// consumed exactly once by [StructBuilder.adoptPointerField] or
/// [MessageBuilder.adoptRoot] — adopting the same Orphan twice throws
/// [StateError].
sealed class Orphan {
  final ArenaBuilder _arena;
  bool _consumed = false;

  Orphan._(this._arena);
}

/// An orphaned struct.
final class StructOrphan extends Orphan {
  final RawStructBuilder raw;
  StructOrphan._(super.arena, this.raw) : super._();
}

/// An orphaned list (including Text/Data, which are byte-element lists).
final class ListOrphan extends Orphan {
  final RawListBuilder raw;
  ListOrphan._(super.arena, this.raw) : super._();
}

enum _PointerKind { struct, list }

/// Determines whether the (possibly far, possibly double-far) pointer at
/// [wordOffset] in [seg] ultimately refers to a struct or a list, without
/// fully resolving it. Mirrors message_copy.dart's _copyPointer dispatch
/// shape for following far pointers, but only far enough to answer "which
/// resolver do I call".
_PointerKind _peekKind(ArenaReader arena, SegmentReader seg, int wordOffset) {
  final ptr = WirePointer.decode(seg.data, wordOffset);
  if (ptr is StructPointer) return _PointerKind.struct;
  if (ptr is ListPointer) return _PointerKind.list;
  if (ptr is FarPointer) {
    if (!ptr.isDoubleFar) {
      return _peekKind(
        arena,
        arena.getSegment(ptr.segmentId),
        ptr.landingPadOffset,
      );
    }
    final targetSeg = arena.getSegment(ptr.segmentId);
    final inner = WirePointer.decode(targetSeg.data, ptr.landingPadOffset);
    if (inner is! FarPointer || inner.isDoubleFar) {
      throw const DecodeException('invalid double-far inner pointer');
    }
    final tag = WirePointer.decode(targetSeg.data, ptr.landingPadOffset + 1);
    if (tag is StructPointer) return _PointerKind.struct;
    if (tag is ListPointer) return _PointerKind.list;
    throw DecodeException('invalid double-far tag: ${tag.runtimeType}');
  }
  throw StateError('unreachable pointer kind: ${ptr.runtimeType}');
}

/// Detaches the pointer at [ptrWordOffset] in [ptrSeg], returning it as an
/// [Orphan]. The slot reads as unset immediately after this call. Returns
/// null if the slot was already unset (null pointer).
///
/// Throws [UnsupportedError] if the slot holds a capability pointer (see the
/// file-level doc comment).
Orphan? disownPointer(ArenaBuilder arena, SegmentBuilder ptrSeg, int ptrWordOffset) {
  final peeked = WirePointer.decode(ptrSeg.data, ptrWordOffset);
  if (peeked is NullPointer) return null;
  if (peeked is CapabilityPointer) {
    throw UnsupportedError(
      'capability pointers cannot be orphaned: a capability index is only '
      "meaningful together with its message's capability table, which this "
      'serialization-only runtime has no concept of',
    );
  }

  final readerArena = ArenaReader.fromBuilder(arena);
  final srcSegReader = readerArena.getSegment(ptrSeg.id);
  final kind = _peekKind(readerArena, srcSegReader, ptrWordOffset);

  final Orphan orphan;
  if (kind == _PointerKind.struct) {
    final resolved = readerArena.resolveStructAt(srcSegReader, ptrWordOffset, 64);
    orphan = StructOrphan._(
      arena,
      RawStructBuilder(
        segment: arena.getSegment(resolved.segment.id),
        arena: arena,
        dataWordOffset: resolved.dataWordOffset,
        dataWords: resolved.dataWords,
        ptrWordOffset: resolved.ptrWordOffset,
        ptrWords: resolved.ptrWords,
      ),
    );
  } else {
    final resolved = readerArena.resolveListAt(srcSegReader, ptrWordOffset, 64)!;
    orphan = ListOrphan._(
      arena,
      RawListBuilder(
        segment: arena.getSegment(resolved.segment.id),
        arena: arena,
        dataByteOffset: resolved.dataByteOffset,
        elementSize: resolved.elementSize,
        elementCount: resolved.elementCount,
        structDataWords: resolved.structDataWords,
        structPtrWords: resolved.structPtrWords,
      ),
    );
  }

  const NullPointer().encode(ptrSeg.data, ptrWordOffset);
  return orphan;
}

/// Adopts [orphan] into the pointer at [ptrWordOffset] in [ptrSeg], replacing
/// whatever was there. Passing null clears the slot.
///
/// Throws [ArgumentError] if [orphan] was disowned from a different arena
/// (see the file-level doc comment), or [StateError] if it was already
/// adopted.
void adoptPointer(
  ArenaBuilder arena,
  SegmentBuilder ptrSeg,
  int ptrWordOffset,
  Orphan? orphan,
) {
  if (orphan == null) {
    const NullPointer().encode(ptrSeg.data, ptrWordOffset);
    return;
  }
  if (orphan._arena != arena) {
    throw ArgumentError(
      'Orphan belongs to a different MessageBuilder/arena; zero-copy '
      'adoption only works within the same message. To move content into '
      'a different message, use copyMessageRootToBuilder / '
      'copyAnyPointerToNewMessage from message_copy.dart instead.',
    );
  }
  if (orphan._consumed) {
    throw StateError('this Orphan has already been adopted');
  }
  orphan._consumed = true;

  switch (orphan) {
    case StructOrphan(:final raw):
      arena.writePointerToExisting(
        ptrSeg: ptrSeg,
        ptrWordOffset: ptrWordOffset,
        targetSeg: raw.segment,
        targetWordOffset: raw.dataWordOffset,
        makePointer: (offset) => StructPointer(
          offset: offset,
          dataWords: raw.dataWords,
          ptrWords: raw.ptrWords,
        ),
      );
    case ListOrphan(:final raw):
      final isComposite = raw.elementSize == ListElementSize.composite;
      // Composite lists' pointer targets the tag word, one word before the
      // element data — matches ArenaBuilder.allocateList's own encoding.
      final targetWordOffset =
          raw.dataByteOffset ~/ bytesPerWord - (isComposite ? 1 : 0);
      final elementCountOrWordCount = isComposite
          ? raw.elementCount * (raw.structDataWords + raw.structPtrWords)
          : raw.elementCount;
      arena.writePointerToExisting(
        ptrSeg: ptrSeg,
        ptrWordOffset: ptrWordOffset,
        targetSeg: raw.segment,
        targetWordOffset: targetWordOffset,
        makePointer: (offset) => ListPointer(
          offset: offset,
          elementSize: raw.elementSize,
          elementCountOrWordCount: elementCountOrWordCount,
        ),
      );
  }
}
