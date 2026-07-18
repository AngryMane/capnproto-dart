import 'package:capnproto_dart/capnproto_dart.dart';

/// Thrown when an RPC call fails (e.g., connection lost, remote exception,
/// method not found).
class RpcException extends CapnpException {
  const RpcException(super.message, {super.kind, super.cause});
}
