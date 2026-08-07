part of 'capability.dart';

/// Resolves the capability at pointer slot [ptrIndex], or throws an
/// [RpcException] that preserves why the pipeline target could not resolve.
///
/// Used for *local*, single-hop pipelining where [ptrIndex] is a
/// schema-known constant baked into generated code — `_DeferredDispatchHandle`,
/// `_FutureDispatchHandle`, `_ErrorDispatchHandle`, and
/// `_UnresolvedImportDispatchHandle`'s already-settled fallback in the RPC
/// layer. Wire-level `receiverAnswer`/`promisedAnswer` targets instead go through
/// [requireCapabilityFromResultPath], since those can name a capability
/// nested more than one struct deep in the result.
///
/// Returns a vended handle (see [vendCapabilityHandle]), not the raw
/// [DispatchResult.caps] entry directly: the same underlying capability is
/// commonly reachable through more than one independent path from generated
/// code (e.g. an eagerly-pipelined `XxxPipeline.someCap` and the same field
/// read off the awaited `XxxPipeline.result` reader both resolve to the
/// identical [DispatchResult.caps] entry), and disposing one such reference
/// must not silently invalidate the other.
Capability requireCapabilityFromResult(DispatchResult result, int ptrIndex) {
  if (result.caps.isEmpty) {
    throw const RpcException('result has no capability table entries');
  }
  try {
    final root = result.payload.getRootRaw();
    if (ptrIndex < 0 || ptrIndex >= root.ptrWords) {
      throw RpcException('pointer slot $ptrIndex is out of range');
    }
    final ptr = WirePointer.decode(
      root.segment.data,
      root.ptrWordOffset + ptrIndex,
    );
    if (ptr is! CapabilityPointer) {
      throw RpcException(
        'pointer slot $ptrIndex in result struct is not a capability',
      );
    }
    final capIdx = ptr.capabilityIndex;
    if (capIdx >= result.caps.length) {
      throw RpcException(
        'capability table index $capIdx is out of range for ${result.caps.length} result capabilities',
      );
    }
    return vendCapabilityHandle(result.caps[capIdx]);
  } on RpcException {
    rethrow;
  } catch (e) {
    throw RpcException('failed to decode result capability: $e');
  }
}

/// Like [requireCapabilityFromResult], but resolves a capability reachable
/// via a chain of pointer-field hops (`path`) rather than a single
/// top-level index — used when a wire-level `receiverAnswer`/
/// `promisedAnswer` transform names a capability nested more than one
/// struct deep in the result (see rpc.capnp's `PromisedAnswer.Op`; each
/// entry but the last is followed as a nested struct pointer, the last as
/// the capability itself). Returns null instead of throwing on any
/// resolution failure.
Capability? capabilityFromResultPath(DispatchResult result, List<int> path) {
  try {
    return requireCapabilityFromResultPath(result, path);
  } catch (_) {
    return null;
  }
}

/// Throwing counterpart of [capabilityFromResultPath] — see
/// [requireCapabilityFromResult] for the single-hop version this
/// generalizes.
Capability requireCapabilityFromResultPath(
  DispatchResult result,
  List<int> path,
) {
  if (path.isEmpty) {
    throw const RpcException('transform path must not be empty');
  }
  if (result.caps.isEmpty) {
    throw const RpcException('result has no capability table entries');
  }
  try {
    var raw = result.payload.getRootRaw();
    for (var i = 0; i < path.length - 1; i++) {
      final idx = path[i];
      if (idx < 0 || idx >= raw.ptrWords) {
        throw RpcException(
          'pointer slot $idx in transform path is out of range',
        );
      }
      final next = raw.arena.resolveOptionalStructAt(
        raw.segment,
        raw.ptrWordOffset + idx,
        raw.nestingLimit,
      );
      if (next == null) {
        throw RpcException('pointer slot $idx in transform path is null');
      }
      raw = next;
    }
    final lastIdx = path.last;
    if (lastIdx < 0 || lastIdx >= raw.ptrWords) {
      throw RpcException('pointer slot $lastIdx is out of range');
    }
    final ptr = WirePointer.decode(
      raw.segment.data,
      raw.ptrWordOffset + lastIdx,
    );
    if (ptr is! CapabilityPointer) {
      throw RpcException(
        'pointer slot $lastIdx in result struct is not a capability',
      );
    }
    final capIdx = ptr.capabilityIndex;
    if (capIdx >= result.caps.length) {
      throw RpcException(
        'capability table index $capIdx is out of range for ${result.caps.length} result capabilities',
      );
    }
    return vendCapabilityHandle(result.caps[capIdx]);
  } on RpcException {
    rethrow;
  } catch (e) {
    throw RpcException('failed to decode result capability: $e');
  }
}
