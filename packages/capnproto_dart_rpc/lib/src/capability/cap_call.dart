part of 'capability.dart';

/// Represents an in-progress dispatch call.
///
/// Returned by [Capability.beginDispatch]. Carries the result future and a
/// factory for creating a capability that pipelines onto the result's caps
/// without waiting for the round-trip to complete.
abstract interface class CapCall {
  /// The eventual result of the dispatched call.
  Future<DispatchResult> get result;

  /// Returns a capability that targets pointer field [ptrIndex] of the result
  /// struct's capTable — usable immediately, before [result] completes.
  Capability pipelineResult(int ptrIndex);

  /// Like [pipelineResult], but for a capability reachable via a chain of
  /// pointer-field hops (each entry but the last followed as a nested
  /// struct pointer, the last as the capability itself) rather than a
  /// single top-level index — used by generated code when a result
  /// capability is nested inside one or more struct-typed fields instead of
  /// sitting directly on the result struct.
  ///
  /// [path] is never empty. Implementations that don't support multi-hop
  /// pipelining can implement this as:
  /// ```dart
  /// Capability pipelineResultPath(List<int> path) {
  ///   if (path.length == 1) return pipelineResult(path[0]);
  ///   throw UnsupportedError('multi-hop pipelining not supported');
  /// }
  /// ```
  /// (this is exactly what every `implements CapCall` class in this library
  /// does unless it can actually resolve deeper paths before [result]
  /// completes — see `_PipelinedCapability` in the RPC layer for the
  /// one that can). Note that — unlike an `abstract class` — `interface
  /// class` member bodies aren't inherited by `implements`, so every
  /// implementation, including this library's own, must define this method
  /// itself; there is no free default.
  Capability pipelineResultPath(List<int> path);
}
