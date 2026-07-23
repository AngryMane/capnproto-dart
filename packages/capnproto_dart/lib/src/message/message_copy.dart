// Deep-copy utilities for Cap'n Proto objects.
//
// Used by the RPC layer to extract AnyPointer struct fields (Payload.content)
// into standalone messages, enabling interoperability with non-Dart peers.

import 'dart:typed_data';

import '../arena/arena_builder.dart';
import '../arena/arena_reader.dart';
import '../arena/segment_builder.dart';
import '../arena/segment_reader.dart';
import '../exception/decode_exception.dart';
import '../wire/pointer.dart';
import '../wire/wire_helpers.dart';
import 'message_reader_options.dart';

/// Deep-copies [messageBytes] into a new single-segment message.
///
/// This is a bytes-only copy: capability pointers are zeroed because their
/// indices are meaningful only together with the original message's capability
/// table, which is not represented in raw serialized bytes.
///
/// When [preserveCapabilityPointers] is true and [messageBytes] is already a
/// single-segment message, this returns [messageBytes] unchanged. Callers must
/// treat the returned bytes as sharing ownership with the input.
///
/// [options] bounds the re-parse of [messageBytes] (traversal/nesting/segment
/// limits). It defaults to [MessageReaderOptions]'s defaults, but callers
/// parsing untrusted input under a stricter policy should pass the same
/// options they used to read the surrounding message, since this function
/// re-parses [messageBytes] independently and won't otherwise inherit it.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = ensureSingleSegment;
/// ```
Uint8List ensureSingleSegment(
  Uint8List messageBytes, {
  bool preserveCapabilityPointers = false,
  MessageReaderOptions options = const MessageReaderOptions(),
}) {
  if (messageBytes.lengthInBytes < 4) return messageBytes;
  final hdr = ByteData.sublistView(messageBytes, 0, messageBytes.lengthInBytes);
  final numSegmentsMinusOne = readUint32(hdr, 0);

  if (preserveCapabilityPointers && numSegmentsMinusOne == 0) {
    return messageBytes;
  }

  // Calculate total source data words to size the destination arena.
  int totalSourceWords = 0;
  for (int i = 0; i <= numSegmentsMinusOne; i++) {
    totalSourceWords += readUint32(hdr, 4 + i * 4);
  }

  // Deep-copy the root pointer into a pre-sized single-segment arena.
  final srcArena = ArenaReader.fromBytes(messageBytes, options);
  // Add 64 words of overhead for the root pointer slot and alignment.
  final dst = ArenaBuilder(totalSourceWords + 64);
  final (ptrSeg, rootPtrOffset) = dst.allocate(1);
  _copyPointer(
    srcArena,
    srcArena.getSegment(0),
    0,
    srcArena.nestingLimit,
    dst,
    ptrSeg,
    rootPtrOffset,
    preserveCapabilityPointers: preserveCapabilityPointers,
  );
  return dst.serialize();
}

/// Deep-copies the root pointer of [messageBytes] into [dstArena] at
/// [dstPtrSeg]/[dstPtrWordOffset].
///
/// Unlike [ArenaBuilder.writeAnyPointerFromMessage], this is pointer-aware: it
/// can read multi-segment source messages and follows far pointers through the
/// source arena. Capability pointers are zeroed by default because their table
/// is not part of the raw message bytes; RPC callers that carry the matching
/// capability table can set [preserveCapabilityPointers].
///
/// [options] bounds the re-parse of [messageBytes] (see [ensureSingleSegment]).
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = copyMessageRootToBuilder;
/// ```
void copyMessageRootToBuilder(
  Uint8List messageBytes,
  ArenaBuilder dstArena,
  SegmentBuilder dstPtrSeg,
  int dstPtrWordOffset, {
  bool preserveCapabilityPointers = false,
  MessageReaderOptions options = const MessageReaderOptions(),
}) {
  final srcArena = ArenaReader.fromBytes(messageBytes, options);
  _copyPointer(
    srcArena,
    srcArena.getSegment(0),
    0,
    srcArena.nestingLimit,
    dstArena,
    dstPtrSeg,
    dstPtrWordOffset,
    preserveCapabilityPointers: preserveCapabilityPointers,
  );
}

/// Reads the AnyPointer at ptr slot [ptrIndex] of [host], deep-copies the
/// referenced struct into a new standalone message, and returns the serialized
/// bytes. Returns null if the pointer is null. Top-level capability pointers
/// are returned only when [preserveCapabilityPointers] is true.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = copyAnyPointerToNewMessage;
/// ```
Uint8List? copyAnyPointerToNewMessage(
  RawStructReader host,
  int ptrIndex, {
  bool preserveCapabilityPointers = false,
}) {
  if (ptrIndex < 0 || ptrIndex >= host.ptrWords) return null;
  final ptrWordOffset = host.ptrWordOffset + ptrIndex;

  // Peek at the pointer type before attempting resolution.
  final peeked = WirePointer.decode(host.segment.data, ptrWordOffset);
  if (peeked is NullPointer) return null;
  if (peeked is CapabilityPointer && !preserveCapabilityPointers) return null;
  // Delegate to the general pointer copier so struct, list (Text/Data/
  // List(T)), and capability payloads are all handled uniformly — the
  // AnyPointer's actual wire representation isn't necessarily a struct.
  final dst = ArenaBuilder();
  final (ptrSeg, rootPtrOffset) = dst.allocate(1);
  _copyPointer(
    host.arena,
    host.segment,
    ptrWordOffset,
    host.nestingLimit,
    dst,
    ptrSeg,
    rootPtrOffset,
    preserveCapabilityPointers: preserveCapabilityPointers,
  );
  return dst.serialize();
}

/// Deep-copies the root pointer of [messageBytes] into the
/// [canonical](https://capnproto.org/encoding.html#canonicalization) form of
/// the message: every struct's data and pointer sections are trimmed of
/// trailing default-valued (all-zero / null) words, and lists of structs are
/// re-packed to the smallest uniform element size that still fits every
/// element.
///
/// The returned bytes are the raw words of that single canonical segment —
/// starting with the root pointer word — with no Cap'n Proto message framing
/// (no segment-count/segment-size header). This matches capnp-rust's
/// `message::Reader::canonicalize()` (whose result is likewise the bare
/// segment content, not a standalone re-parseable message) and the `capnp`
/// CLI's `canonical` output format, so it's suitable for byte-for-byte
/// comparison against either.
///
/// Throws [DecodeException] if the message contains a capability pointer
/// anywhere, since a capability's meaning depends on a side-channel table
/// that isn't part of the canonical byte representation.
///
/// **Intended users**
/// * Application and tooling developers using the public runtime API.
///
/// **Primary use cases**
/// * Converts messages or schema metadata for serialization, diagnostics, or dynamic processing.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * The converted message, text, or schema-registry value.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final canonical = canonicalizeMessage(messageBytes);
/// ```
Uint8List canonicalizeMessage(
  Uint8List messageBytes, [
  MessageReaderOptions options = const MessageReaderOptions(),

  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = canonicalizeArena;
  /// ```
]) => canonicalizeArena(ArenaReader.fromBytes(messageBytes, options));

/// Same as [canonicalizeMessage] but operating on an already-parsed
/// [ArenaReader], avoiding a redundant re-parse of the source bytes.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = canonicalizeArena;
/// ```
Uint8List canonicalizeArena(ArenaReader srcArena) {
  var totalSourceWords = 0;
  for (var i = 0; i < srcArena.segmentCount; i++) {
    totalSourceWords += srcArena.getSegment(i).wordCount;
  }

  // Canonicalization only ever trims trailing default-valued words, so a
  // single segment sized to the whole source message is always large enough
  // to hold the result without spilling into a second segment.
  final dst = ArenaBuilder(totalSourceWords + 1);
  final (ptrSeg, rootPtrOffset) = dst.allocate(1);
  _copyPointer(
    srcArena,
    srcArena.getSegment(0),
    0,
    srcArena.nestingLimit,
    dst,
    ptrSeg,
    rootPtrOffset,
    canonicalize: true,
  );
  assert(
    dst.segmentCount == 1,
    'canonicalization must fit in a single pre-sized segment',
  );
  final seg0 = dst.getSegment(0).usedData;
  return seg0.buffer.asUint8List(seg0.offsetInBytes, seg0.lengthInBytes);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Returns the largest `n <= wordCount` such that word `n` (and everything
/// after it) is either out of range or entirely zero, i.e. the word count
/// left after trimming trailing all-zero words from [byteOffset].
int _trimTrailingZeroWords(ByteData data, int byteOffset, int wordCount) {
  final buf = data.buffer.asUint8List(data.offsetInBytes);
  while (wordCount > 0) {
    final wordStart = byteOffset + (wordCount - 1) * bytesPerWord;
    var allZero = true;
    for (var b = 0; b < bytesPerWord; b++) {
      if (buf[wordStart + b] != 0) {
        allZero = false;
        break;
      }
    }
    if (!allZero) break;
    wordCount--;
  }
  return wordCount;
}

/// Returns the largest `n <= ptrWords` such that pointer slots `[n,
/// ptrWords)` starting at word [ptrWordOffset] of [segment] are all null.
int _trimTrailingNullPointers(
  SegmentReader segment,
  int ptrWordOffset,
  int ptrWords,
) {
  while (ptrWords > 0 &&
      WirePointer.decode(segment.data, ptrWordOffset + ptrWords - 1)
          is NullPointer) {
    ptrWords--;
  }
  return ptrWords;
}

/// Deep-copies the already-resolved struct [src] into [dstArena] at
/// [dstPtrSeg]/[dstPtrWordOffset].
///
/// Unlike [copyMessageRootToBuilder], [src] is not raw message bytes that
/// need parsing first — it's a [RawStructReader] already resolved from
/// somewhere in memory (e.g. [StructBuilder.rawToReader]'s zero-copy view
/// onto a builder's own in-progress content). This skips the
/// serialize-then-reparse round trip that a bytes-based copy would require,
/// while the destination copy itself remains a real copy (same as
/// [copyMessageRootToBuilder]) — [src] and the destination are still
/// different arenas.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = copyStructToBuilder;
/// ```
void copyStructToBuilder(
  RawStructReader src,
  ArenaBuilder dstArena,
  SegmentBuilder dstPtrSeg,
  int dstPtrWordOffset, {
  bool preserveCapabilityPointers = false,
}) => _copyStruct(
  src,
  src.arena,
  dstArena,
  dstPtrSeg,
  dstPtrWordOffset,
  preserveCapabilityPointers: preserveCapabilityPointers,
);

void _copyStruct(
  RawStructReader src,
  ArenaReader srcArena,
  ArenaBuilder dstArena,
  SegmentBuilder dstPtrSeg,
  int dstPtrWordOffset, {
  bool preserveCapabilityPointers = false,
  bool canonicalize = false,
}) {
  var dataWords = src.dataWords;
  var ptrWords = src.ptrWords;
  if (canonicalize) {
    dataWords = _trimTrailingZeroWords(
      src.segment.data,
      src.dataWordOffset * bytesPerWord,
      dataWords,
    );
    ptrWords = _trimTrailingNullPointers(
      src.segment,
      src.ptrWordOffset,
      ptrWords,
    );
  }
  final dst = dstArena.allocateStruct(
    ptrSeg: dstPtrSeg,
    ptrWordOffset: dstPtrWordOffset,
    dataWords: dataWords,
    ptrWords: ptrWords,
  );

  // Copy data section byte-by-byte.
  if (dataWords > 0) {
    final byteCount = dataWords * bytesPerWord;
    final srcBase = src.dataWordOffset * bytesPerWord;
    final dstBase = dst.dataWordOffset * bytesPerWord;
    final srcBuf = src.segment.data.buffer.asUint8List(
      src.segment.data.offsetInBytes,
    );
    final dstBuf = dst.segment.data.buffer.asUint8List();
    dstBuf.setRange(dstBase, dstBase + byteCount, srcBuf, srcBase);
  }

  // Recursively copy pointer section. src.ptrWordOffset is fixed by the
  // struct's original (untrimmed) layout, so it stays correct as the
  // pointer-section base even when dataWords was trimmed above.
  for (var i = 0; i < ptrWords; i++) {
    _copyPointer(
      srcArena,
      src.segment,
      src.ptrWordOffset + i,
      src.nestingLimit,
      dstArena,
      dst.segment,
      dst.ptrWordOffset + i,
      preserveCapabilityPointers: preserveCapabilityPointers,
      canonicalize: canonicalize,
    );
  }
}

void _copyPointer(
  ArenaReader srcArena,
  SegmentReader srcSeg,
  int srcPtrWordOffset,
  int nestingLimit,
  ArenaBuilder dstArena,
  SegmentBuilder dstSeg,
  int dstPtrWordOffset, {
  bool preserveCapabilityPointers = false,
  bool canonicalize = false,
}) {
  final ptr = WirePointer.decode(srcSeg.data, srcPtrWordOffset);
  switch (ptr) {
    case NullPointer():
      return; // leave destination slot as zero

    case FarPointer():
      final targetSeg = srcArena.getSegment(ptr.segmentId);
      if (!ptr.isDoubleFar) {
        _copyPointer(
          srcArena,
          targetSeg,
          ptr.landingPadOffset,
          nestingLimit,
          dstArena,
          dstSeg,
          dstPtrWordOffset,
          preserveCapabilityPointers: preserveCapabilityPointers,
          canonicalize: canonicalize,
        );
      } else {
        // Double-far landing pad: [far_ptr, tag]. The tag's own discriminant
        // (struct vs list) says which resolver + copier this delegates to.
        // srcArena.resolveStructAt/resolveListAt re-walk the *original*
        // far pointer (including the double-far case) using the same
        // validated logic the direct (non-copy) reader path relies on —
        // reusing that here instead of hand-rebuilding a RawStructReader/
        // RawListReader from the landing pad avoids a second, easily
        // divergent implementation of that math (this hand-rolled version
        // previously only handled a struct tag, silently dropping lists).
        final inner = WirePointer.decode(targetSeg.data, ptr.landingPadOffset);
        if (inner is! FarPointer || inner.isDoubleFar) {
          throw const DecodeException('invalid double-far inner pointer');
        }
        final tag = WirePointer.decode(
          targetSeg.data,
          ptr.landingPadOffset + 1,
        );
        switch (tag) {
          case StructPointer():
            _copyStruct(
              srcArena.resolveStructAt(srcSeg, srcPtrWordOffset, nestingLimit),
              srcArena,
              dstArena,
              dstSeg,
              dstPtrWordOffset,
              preserveCapabilityPointers: preserveCapabilityPointers,
              canonicalize: canonicalize,
            );
          case ListPointer():
            _copyList(
              srcArena,
              srcSeg,
              srcPtrWordOffset,
              nestingLimit,
              dstArena,
              dstSeg,
              dstPtrWordOffset,
              preserveCapabilityPointers: preserveCapabilityPointers,
              canonicalize: canonicalize,
            );
          default:
            throw DecodeException('invalid double-far tag: ${tag.runtimeType}');
        }
      }

    case StructPointer():
      final structSrc = srcArena.resolveStructAt(
        srcSeg,
        srcPtrWordOffset,
        nestingLimit,
      );
      _copyStruct(
        structSrc,
        srcArena,
        dstArena,
        dstSeg,
        dstPtrWordOffset,
        preserveCapabilityPointers: preserveCapabilityPointers,
        canonicalize: canonicalize,
      );

    case ListPointer():
      _copyList(
        srcArena,
        srcSeg,
        srcPtrWordOffset,
        nestingLimit,
        dstArena,
        dstSeg,
        dstPtrWordOffset,
        preserveCapabilityPointers: preserveCapabilityPointers,
        canonicalize: canonicalize,
      );

    case CapabilityPointer():
      if (canonicalize) {
        throw const DecodeException(
          'cannot create a canonical message with a capability',
        );
      }
      if (preserveCapabilityPointers) {
        final byteOffset = srcPtrWordOffset * bytesPerWord;
        final dstByteOffset = dstPtrWordOffset * bytesPerWord;
        writeUint32(
          dstSeg.data,
          dstByteOffset,
          readUint32(srcSeg.data, byteOffset),
        );
        writeUint32(
          dstSeg.data,
          dstByteOffset + 4,
          readUint32(srcSeg.data, byteOffset + 4),
        );
        break;
      }
      // Zero out capability pointers during deep copy: a capabilityIndex is
      // only meaningful within its own message's cap table. Without also
      // copying the cap table the index would be a dangling reference.
      // Callers that need capability-aware transfer (e.g. RPC dispatch) use
      // MessageReader.deserialize() directly rather than going through this
      // deep-copy path.
      break; // destination slot remains zeroed
  }
}

void _copyList(
  ArenaReader srcArena,
  SegmentReader srcSeg,
  int srcPtrWordOffset,
  int nestingLimit,
  ArenaBuilder dstArena,
  SegmentBuilder dstSeg,
  int dstPtrWordOffset, {
  bool preserveCapabilityPointers = false,
  bool canonicalize = false,
}) {
  final raw = srcArena.resolveListAt(srcSeg, srcPtrWordOffset, nestingLimit);
  if (raw == null) return;

  switch (raw.elementSize) {
    case ListElementSize.byte:
      // Text or Data: copy elementCount bytes verbatim (includes null
      // terminator for Text, which is counted in elementCount). List
      // contents are actual data, not defaultable fields, so canonicalize
      // never trims them.
      final bytes = Uint8List(raw.elementCount);
      final srcBuf = raw.segment.data.buffer.asUint8List(
        raw.segment.data.offsetInBytes,
      );
      bytes.setRange(0, raw.elementCount, srcBuf, raw.dataByteOffset);
      dstArena.writeDataField(dstSeg, dstPtrWordOffset, bytes);

    case ListElementSize.composite:
      // Every element shares one uniform layout, so canonicalizing trims to
      // the smallest data/pointer section size that still fits every
      // element (not each element's own minimum) — matching capnp-rust.
      var dataWords = raw.structDataWords;
      var ptrWords = raw.structPtrWords;
      if (canonicalize) {
        var maxDataWords = 0;
        var maxPtrWords = 0;
        final elementWords = raw.structDataWords + raw.structPtrWords;
        for (var i = 0; i < raw.elementCount; i++) {
          final elemWordOff =
              raw.dataByteOffset ~/ bytesPerWord + i * elementWords;
          final localDataWords = _trimTrailingZeroWords(
            raw.segment.data,
            elemWordOff * bytesPerWord,
            raw.structDataWords,
          );
          if (localDataWords > maxDataWords) maxDataWords = localDataWords;
          final localPtrWords = _trimTrailingNullPointers(
            raw.segment,
            elemWordOff + raw.structDataWords,
            raw.structPtrWords,
          );
          if (localPtrWords > maxPtrWords) maxPtrWords = localPtrWords;
        }
        dataWords = maxDataWords;
        ptrWords = maxPtrWords;
      }

      final dstList = dstArena.allocateList(
        ptrSeg: dstSeg,
        ptrWordOffset: dstPtrWordOffset,
        elementSize: ListElementSize.composite,
        elementCount: raw.elementCount,
        structDataWords: dataWords,
        structPtrWords: ptrWords,
      );
      // Source elements keep their original (untrimmed) stride; only the
      // destination's per-element layout shrinks.
      final srcElementWords = raw.structDataWords + raw.structPtrWords;
      final dstElementWords = dataWords + ptrWords;
      for (var i = 0; i < raw.elementCount; i++) {
        final srcElemWordOff =
            raw.dataByteOffset ~/ bytesPerWord + i * srcElementWords;
        final dstElemWordOff =
            dstList.dataByteOffset ~/ bytesPerWord + i * dstElementWords;
        // Copy data section.
        if (dataWords > 0) {
          final byteCount = dataWords * bytesPerWord;
          final srcBase = srcElemWordOff * bytesPerWord;
          final dstBase = dstElemWordOff * bytesPerWord;
          final srcBuf = raw.segment.data.buffer.asUint8List(
            raw.segment.data.offsetInBytes,
          );
          final dstBuf = dstList.segment.data.buffer.asUint8List();
          dstBuf.setRange(dstBase, dstBase + byteCount, srcBuf, srcBase);
        }
        // Copy pointer section recursively.
        for (var p = 0; p < ptrWords; p++) {
          _copyPointer(
            srcArena,
            raw.segment,
            srcElemWordOff + raw.structDataWords + p,
            nestingLimit - 1,
            dstArena,
            dstList.segment,
            dstElemWordOff + dataWords + p,
            preserveCapabilityPointers: preserveCapabilityPointers,
            canonicalize: canonicalize,
          );
        }
      }

    case ListElementSize.pointer:
      final dstList = dstArena.allocateList(
        ptrSeg: dstSeg,
        ptrWordOffset: dstPtrWordOffset,
        elementSize: ListElementSize.pointer,
        elementCount: raw.elementCount,
      );
      for (var i = 0; i < raw.elementCount; i++) {
        final srcSlot = raw.dataByteOffset ~/ bytesPerWord + i;
        final dstSlot = dstList.dataByteOffset ~/ bytesPerWord + i;
        _copyPointer(
          srcArena,
          raw.segment,
          srcSlot,
          nestingLimit - 1,
          dstArena,
          dstList.segment,
          dstSlot,
          preserveCapabilityPointers: preserveCapabilityPointers,
          canonicalize: canonicalize,
        );
      }

    default:
      // Primitive lists (void, bit, 2/4/8-byte values): raw byte copy.
      final wordCount = listDataWordCount(raw.elementSize, raw.elementCount);
      final dstList = dstArena.allocateList(
        ptrSeg: dstSeg,
        ptrWordOffset: dstPtrWordOffset,
        elementSize: raw.elementSize,
        elementCount: raw.elementCount,
      );
      if (wordCount == 0) return;
      final byteCount = wordCount * bytesPerWord;
      final srcBuf = raw.segment.data.buffer.asUint8List(
        raw.segment.data.offsetInBytes,
      );
      final dstBuf = dstList.segment.data.buffer.asUint8List();
      dstBuf.setRange(
        dstList.dataByteOffset,
        dstList.dataByteOffset + byteCount,
        srcBuf,
        raw.dataByteOffset,
      );
  }
}
