import 'capnp_exception.dart';

/// Reports malformed input or a configured decoding-limit violation.
///
/// **Intended users**
/// * Application and library developers working with Cap'n Proto messages.
///
/// **Primary use cases**
/// * Reads, writes, validates, or reports failures for application messages.
class DecodeException extends CapnpException {
  /// Creates a [DecodeException] instance.
  const DecodeException(super.message, {super.kind, super.cause});

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = value.toString;
  /// ```
  String toString() {
    final base = 'DecodeException: $message';
    return cause == null ? base : '$base (caused by: $cause)';
  }
}
