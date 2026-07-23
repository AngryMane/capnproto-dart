import 'dart:typed_data';

import '../arena/arena_builder.dart';
import '../debug/perf_log.dart';
import '../layout/any_pointer.dart' show AnyPointerBuilder, DynamicStructBuilder;
import '../layout/orphan.dart';
import '../layout/struct_builder.dart';
import '../layout/struct_factory.dart';
import '../layout/struct_reader.dart';
import '../stream/packed_codec.dart';

/// Builds and serializes a Cap'n Proto message.
///
/// **Intended users**
/// * Application and library developers working with Cap'n Proto messages.
///
/// **Primary use cases**
/// * Creates a typed or reflection-driven root and serializes the resulting
///   message for transport or storage.
///
/// **Key features / components**
/// * [initRoot] creates roots backed by generated types.
/// * [initDynamicRoot] creates roots from runtime schema metadata.
/// * [serialize] and [serializePacked] produce framed message bytes.
class MessageBuilder {
  final ArenaBuilder _arena;

  /// Creates a [MessageBuilder] instance.
  ///
  /// [initialCapacityWords] sizes the first segment's freshly heap-allocated
  /// buffer (see [ArenaBuilder.new]) — defaults to a generously-sized 2 KiB
  /// on the assumption that a typical caller doesn't know its message's
  /// eventual size up front. Callers that build many small, similarly-shaped
  /// messages (e.g. RPC envelopes) and know that ahead of time can pass a
  /// much smaller value to avoid over-allocating on every single message —
  /// [ArenaBuilder.allocate] transparently grows into additional segments if
  /// the estimate turns out too small, so an under-estimate only costs a
  /// little extra work on the rare oversized message, never correctness.
  MessageBuilder({int? initialCapacityWords})
    : _arena = timePerf(
        'MessageBuilder()',
        () => initialCapacityWords == null
            ? ArenaBuilder()
            : ArenaBuilder(initialCapacityWords),
      );

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

  /// Initializes and returns a typed root builder.
  ///
  /// [factory] supplies the root layout and converts the allocated raw struct
  /// into [B]. This method must be called before writing root fields.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final root = builder.initRoot(myStructFactory);
  /// ```
  B initRoot<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory,
  ) => timePerf('MessageBuilder.initRoot', () {
    // Allocate the root pointer slot (word 0 of segment 0).
    final (ptrSeg, ptrWordOffset) = _arena.allocate(1);
    final raw = _arena.allocateStruct(
      ptrSeg: ptrSeg,
      ptrWordOffset: ptrWordOffset,
      dataWords: factory.dataWords,
      ptrWords: factory.ptrWords,
    );
    return factory.fromRawBuilder(raw);
  });

  /// Allocates the root pointer slot as a schema-less [AnyPointerBuilder],
  /// for callers that don't know (or don't want to commit to) the root's
  /// type until a later point — e.g. an RPC layer building call params
  /// directly into a caller-supplied destination via [AnyPointerBuilder.
  /// initStruct] instead of [initRoot].
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final root = builder.initAnyPointerRoot();
  /// ```
  AnyPointerBuilder initAnyPointerRoot() => timePerf(
    'MessageBuilder.initAnyPointerRoot',
    () {
      final (ptrSeg, ptrWordOffset) = _arena.allocate(1);
      final owner = RawStructBuilder(
        segment: ptrSeg,
        arena: _arena,
        dataWordOffset: 0,
        dataWords: 0,
        ptrWordOffset: ptrWordOffset,
        ptrWords: 1,
      );
      return AnyPointerBuilder(owner, 0);
    },
  );

  /// Allocates the root struct as a schema-less [DynamicStructBuilder] with
  /// [dataWords]/[pointerWords] words, for callers building a message purely
  /// from runtime [StructSchemaInfo] reflection metadata (see
  /// `text_format.dart`'s `decodeText`) rather than a generated
  /// [StructFactory].
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final child = builder.initDynamicRoot(dataWords: 1, pointerWords: 1);
  /// ```
  DynamicStructBuilder initDynamicRoot({
    required int dataWords,
    required int pointerWords,
  }) {
    final (ptrSeg, ptrWordOffset) = _arena.allocate(1);
    final raw = _arena.allocateStruct(
      ptrSeg: ptrSeg,
      ptrWordOffset: ptrWordOffset,
      dataWords: dataWords,
      ptrWords: pointerWords,
    );
    return DynamicStructBuilder(raw);
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
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = builder.adoptRoot;
  /// ```
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

  /// Resets this builder for reuse by a new message, avoiding a fresh
  /// [ArenaBuilder]/[SegmentBuilder]/backing-buffer allocation for each
  /// message built in a hot loop (e.g. an RPC server building many
  /// short-lived response messages) — see [ArenaBuilder.reset].
  ///
  /// The next call must be [initRoot] (or [initDynamicRoot]) again; this
  /// does not preserve whatever was previously built. Every builder
  /// obtained from this [MessageBuilder] before calling [reset] — including
  /// the previous root and anything nested under it — describes memory this
  /// call is about to hand out again for unrelated content; do not use them
  /// afterward.
  ///
  /// **Example**
  /// ```dart
  /// final message = MessageBuilder();
  /// for (final item in items) {
  ///   final root = message.initRoot(itemFactory);
  ///   root.value = item;
  ///   send(message.serialize());
  ///   message.reset();
  /// }
  /// ```
  void reset() => _arena.reset();

  /// Serializes this message using standard Cap'n Proto framing.
  ///
  /// Returns a snapshot of all currently allocated segments.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final bytes = builder.serialize();
  /// ```
  Uint8List serialize() => timePerf('MessageBuilder.serialize', _arena.serialize);

  /// Serializes this message using Cap'n Proto packed encoding.
  ///
  /// Returns a packed snapshot suitable for storage or transport.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final packedBytes = builder.serializePacked();
  /// ```
  Uint8List serializePacked() =>
      timePerf('MessageBuilder.serializePacked', () => packBytes(serialize()));
}
