/// Configures resource limits applied while decoding a message.
///
/// **Intended users**
/// * Application and library developers working with Cap'n Proto messages.
///
/// **Primary use cases**
/// * Reads, writes, validates, or reports failures for application messages.
class MessageReaderOptions {
  /// Maximum number of 8-byte words allowed to be traversed.
  /// Guards against amplification attacks. Default: 8 * 1024 * 1024 (64 MiB).
  final int traversalLimitInWords;

  /// Maximum pointer nesting depth allowed.
  /// Guards against stack overflow. Default: 64.
  final int nestingLimit;

  /// Maximum number of segments a message's framing header may declare.
  /// Guards against a small message claiming an enormous segment count and
  /// forcing a correspondingly large up-front allocation before any content
  /// is read. Legitimate messages essentially never need more than a
  /// handful of segments. Default: 512.
  final int maxSegments;

  /// Creates a [MessageReaderOptions] instance.
  const MessageReaderOptions({
    this.traversalLimitInWords = 8 * 1024 * 1024,
    this.nestingLimit = 64,
    this.maxSegments = 512,
  });
}
