import 'capnp_exception.dart';

class SchemaException extends CapnpException {
  const SchemaException(super.message);

  @override
  String toString() => 'SchemaException: $message';
}
