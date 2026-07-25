import 'package:capnproto_dart/capnproto_dart.dart';

/// Thrown when an RPC call fails (e.g., connection lost, remote exception,
/// method not found).
class RpcException extends CapnpException {
  /// Creates an RPC exception with the given [message] and optional [kind]/
  /// [cause].
  const RpcException(super.message, {super.kind, super.cause});
}
