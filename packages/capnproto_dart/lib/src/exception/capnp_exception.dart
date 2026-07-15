class CapnpException implements Exception {
  final String message;
  const CapnpException(this.message);

  @override
  String toString() => 'CapnpException: $message';
}
