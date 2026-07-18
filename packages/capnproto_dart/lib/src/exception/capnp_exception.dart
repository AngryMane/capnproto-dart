/// Broad classification of why a Cap'n Proto operation failed — mirrors
/// `capnp::ErrorKind` so it round-trips losslessly with real Cap'n Proto
/// peers over RPC (see `rpc.capnp`'s `Exception.Type`, whose wire values
/// match this enum's declaration order exactly: index 0 = failed ... 3 =
/// unimplemented).
enum ErrorKind {
  /// A generic problem occurred; repeating the operation unchanged would
  /// likely fail the same way. The default for call sites that don't
  /// specify a more precise kind.
  failed,

  /// The operation was rejected due to a temporary lack of resources —
  /// retrying later may succeed.
  overloaded,

  /// The connection or peer this operation depended on is gone.
  disconnected,

  /// The requested operation isn't implemented.
  unimplemented,
}

class CapnpException implements Exception {
  final String message;
  final ErrorKind kind;

  /// The lower-level error this one wraps, if any — Rust's `.context()`
  /// equivalent. Set when a layer catches an error and re-throws with
  /// higher-level meaning, without discarding the original.
  final Object? cause;

  const CapnpException(this.message, {this.kind = ErrorKind.failed, this.cause});

  @override
  String toString() {
    final base = 'CapnpException: $message';
    return cause == null ? base : '$base (caused by: $cause)';
  }
}
