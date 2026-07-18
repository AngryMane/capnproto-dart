import 'dart:typed_data';

import '../arena/arena_builder.dart';
import '../layout/orphan.dart';
import '../layout/struct_builder.dart';
import '../layout/struct_factory.dart';
import '../layout/struct_reader.dart';
import '../stream/packed_codec.dart';

class MessageBuilder {
  final ArenaBuilder _arena;

  MessageBuilder() : _arena = ArenaBuilder();

  /// Builds a message using [scratchSpace] as backing memory for the first
  /// segment instead of a freshly heap-allocated buffer — avoids an
  /// allocation per message when building many messages in a loop with the
  /// same reusable buffer (see [ArenaBuilder.withScratchSpace]).
  ///
  /// The builder aliases [scratchSpace] (including its original buffer offset)
  /// for its entire usable lifetime; it does not copy the bytes. Calling
  /// [serialize] or [serializePacked] returns a snapshot but does not detach or
  /// invalidate this builder. Do not reuse or externally mutate the buffer, or
  /// any overlapping view, while this builder or a derived builder/reader may
  /// still be accessed. Concurrent cross-isolate mutation is unsupported.
  MessageBuilder.withScratchSpace(Uint8List scratchSpace)
    : _arena = ArenaBuilder.withScratchSpace(scratchSpace);

  B initRoot<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory,
  ) {
    // Allocate the root pointer slot (word 0 of segment 0).
    final (ptrSeg, ptrWordOffset) = _arena.allocate(1);
    final raw = _arena.allocateStruct(
      ptrSeg: ptrSeg,
      ptrWordOffset: ptrWordOffset,
      dataWords: factory.dataWords,
      ptrWords: factory.ptrWords,
    );
    return factory.fromRawBuilder(raw);
  }

  /// Adopts [orphan] as this message's root, replacing whatever's there.
  /// Zero-copy — see [StructBuilder.adoptPointerField]. [orphan] must have
  /// been disowned from this same message. On failure, [orphan] remains
  /// available for another adoption attempt.
  ///
  /// The root pointer always lives at word 0 of segment 0. If nothing has
  /// been built in this message yet, that slot is reserved first (exactly
  /// like [initRoot]); otherwise an existing root is overwritten in place —
  /// its bytes simply become unreachable within the arena, same as any
  /// other orphaned content.
  B adoptRoot<R extends StructReader, B extends StructBuilder>(
    StructOrphan orphan,
    StructFactory<R, B> factory,
  ) {
    final rootSeg = _arena.getSegment(0);
    final ptrWordOffset = rootSeg.usedWords == 0 ? _arena.allocate(1).$2 : 0;
    adoptPointer(_arena, rootSeg, ptrWordOffset, orphan);
    final raw = RawStructBuilder(
      segment: orphan.raw.segment,
      arena: _arena,
      dataWordOffset: orphan.raw.dataWordOffset,
      dataWords: orphan.raw.dataWords,
      ptrWordOffset: orphan.raw.ptrWordOffset,
      ptrWords: orphan.raw.ptrWords,
    );
    return factory.fromRawBuilder(raw);
  }

  Uint8List serialize() => _arena.serialize();

  Uint8List serializePacked() => packBytes(serialize());
}
