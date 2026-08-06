import 'dart:async';

/// A reusable RPC reference extracted from a capability bound to the same
/// connection delegate. Capability protocol code uses these values without
/// depending on the private RPC capability proxy implementations.
sealed class RpcCapabilityReference {
  const RpcCapabilityReference();
}

/// A reference to a capability imported from this connection's peer.
/// [importId] is `FutureOr<int>` so a cached ID can remain synchronous, while
/// an unresolved ID can be represented by a `Future<int>`.
final class ImportedCapabilityReference extends RpcCapabilityReference {
  final FutureOr<int> importId;
  const ImportedCapabilityReference(this.importId);
}

/// An unresolved pipelined result targeting [parentQuestionId], one of this
/// connection's outgoing questions, at [transformPath].
final class PipelinedCapabilityReference extends RpcCapabilityReference {
  final int parentQuestionId;
  final List<int> transformPath;

  const PipelinedCapabilityReference({
    required this.parentQuestionId,
    required this.transformPath,
  });
}
