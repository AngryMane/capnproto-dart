import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

/// Wraps RPC call params/results content, whose natural representation
/// differs depending on where it came from:
///
/// * **Freshly built locally, standalone** — a generated client stub or a
///   local [Capability] implementation produced a standalone serialized
///   message. See [RpcPayload.fromBytes].
/// * **Just built, not yet serialized** — a server implementation built
///   results into its own [MessageBuilder] and wants to hand them off
///   without paying for [MessageBuilder.serialize]'s framing step, since
///   what follows is a copy into another arena that doesn't need a framed
///   byte layout. See [RpcPayload.fromBuilder].
/// * **Received over the wire** — a live, not-yet-materialized view into an
///   already-parsed RPC envelope's `Payload.content`. See
///   [RpcPayload.fromEnvelope]. Reading this via [getTyped] resolves
///   directly in the envelope's own arena — no deep copy, no re-parse —
///   unlike the older design where every dispatch first deep-copied
///   `content` out to a standalone message and then re-parsed it.
final class RpcPayload {
  final Uint8List? _bytes;
  final AnyPointerReader? _envelopeContent;
  final RawStructBuilder? _builderRoot;

  const RpcPayload.fromBytes(Uint8List bytes)
    : _bytes = bytes,
      _envelopeContent = null,
      _builderRoot = null;

  const RpcPayload.fromEnvelope(AnyPointerReader content)
    : _bytes = null,
      _envelopeContent = content,
      _builderRoot = null;

  /// Wraps [builder]'s own content in place — no copy, no
  /// [MessageBuilder.serialize] framing step. [builder] must not be mutated
  /// further once wrapped (same aliasing rule as [RpcPayload.fromEnvelope]).
  RpcPayload.fromBuilder(StructBuilder builder)
    : _bytes = null,
      _envelopeContent = null,
      _builderRoot = builder.raw;

  /// Resolves this payload's root struct, without wrapping it in any reader
  /// type — the shared primitive behind [getTyped] and [getDynamic], for
  /// callers that need the raw struct directly (e.g. to inspect a pointer's
  /// wire representation without going through a schema).
  RawStructReader getRootRaw() {
    final content = _envelopeContent;
    if (content != null) return content.resolveStructOrEmpty();
    final builderRoot = _builderRoot;
    if (builderRoot != null) return rawStructBuilderToReader(builderRoot);
    return MessageReader.deserialize(_bytes!).getRootRaw();
  }

  /// Reads this payload as [R], resolving in place when this payload wraps
  /// a live envelope view, or parsing [bytes] otherwise. [capabilities] is
  /// the capability table to resolve capability pointers against — for an
  /// envelope-backed payload this is necessarily supplied here rather than
  /// baked into the payload, since the RPC layer only learns the real
  /// capability table (by resolving capDescriptors) after the envelope has
  /// already been parsed.
  R getTyped<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory, {
    List<Object?> capabilities = const [],
  }) => factory.fromRawReaderWithCapabilities(getRootRaw(), capabilities);

  /// Reads this payload's root as a schema-less [DynamicStructReader].
  DynamicStructReader getDynamic({List<Object?> capabilities = const []}) =>
      DynamicStructReader(getRootRaw(), capabilities: capabilities);

  /// Materializes this payload as standalone bytes — deep-copying if this
  /// wraps a live envelope view, or framing (see [MessageBuilder.serialize])
  /// if this wraps an unserialized builder. Prefer [getTyped]/[getDynamic]
  /// when the caller can consume a reader directly — this forces the same
  /// cost [RpcPayload] exists to let RPC dispatch avoid.
  ///
  /// For a builder-backed payload, this assumes [builderRoot] (see
  /// [RpcPayload.fromBuilder]) is that builder's own message root — true for
  /// the intended use (wrapping a fresh `MessageBuilder().initRoot(...)`
  /// directly), but not meaningful for an arbitrary nested struct builder.
  Uint8List get bytes {
    final bytes = _bytes;
    if (bytes != null) return bytes;
    final builderRoot = _builderRoot;
    if (builderRoot != null) return builderRoot.arena.serialize();
    return _envelopeContent!.asMessageBytes(preserveCapabilityPointers: true) ??
        _emptyMessageBytes;
  }
}

/// Pre-built 16-byte message: single segment, null root pointer. Mirrors
/// [DispatchResult.empty] (kept as a separate literal here to avoid a
/// circular import between rpc_payload.dart and capability.dart).
final Uint8List _emptyMessageBytes = Uint8List.fromList(
  [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
);
