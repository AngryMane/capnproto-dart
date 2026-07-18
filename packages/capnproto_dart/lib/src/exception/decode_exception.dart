import 'capnp_exception.dart';

class DecodeException extends CapnpException {
  const DecodeException(super.message, {super.kind, super.cause});

  @override
  String toString() {
    final base = 'DecodeException: $message';
    return cause == null ? base : '$base (caused by: $cause)';
  }
}
