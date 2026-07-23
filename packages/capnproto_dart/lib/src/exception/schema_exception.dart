import 'capnp_exception.dart';

/// Reports an invalid or unsupported Cap'n Proto schema.
///
/// **Intended users**
/// * Application and library developers working with Cap'n Proto messages.
///
/// **Primary use cases**
/// * Reads, writes, validates, or reports failures for application messages.
class SchemaException extends CapnpException {
  /// Creates a [SchemaException] instance.
  const SchemaException(super.message, {super.kind, super.cause});

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = schema.toString;
  /// ```
  String toString() {
    final base = 'SchemaException: $message';
    return cause == null ? base : '$base (caused by: $cause)';
  }
}
