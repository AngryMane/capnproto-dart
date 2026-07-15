import 'capnp_exception.dart';

class DecodeException extends CapnpException {
  const DecodeException(super.message);

  @override
  String toString() => 'DecodeException: $message';
}
