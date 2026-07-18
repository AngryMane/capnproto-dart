import 'capnp_exception.dart';

class SchemaException extends CapnpException {
  const SchemaException(super.message, {super.kind, super.cause});

  @override
  String toString() {
    final base = 'SchemaException: $message';
    return cause == null ? base : '$base (caused by: $cause)';
  }
}
