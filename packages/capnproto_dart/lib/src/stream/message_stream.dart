import 'dart:typed_data';

import '../exception/decode_exception.dart';
import '../message/message_builder.dart';
import '../message/message_reader.dart';
import '../message/message_reader_options.dart';

/// Utilities for reading and writing streams of Cap'n Proto messages.
///
/// Each message in a stream is framed identically to the single-message format
/// produced by [MessageBuilder.serialize] / read by [MessageReader.deserialize]:
/// a little-endian header followed by segment data. Messages are concatenated
/// back-to-back with no additional delimiters.
class MessageStream {
  const MessageStream._();

  /// Deserializes a stream of framed Cap'n Proto messages.
  ///
  /// Bytes may arrive in arbitrary chunk sizes; the implementation buffers
  /// internally and yields a [MessageReader] for each complete message.
  /// Throws [DecodeException] if the stream ends with a partial message.
  static Stream<MessageReader> deserializeStream(
    Stream<Uint8List> bytes, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) =>
      deserializeStreamRaw(bytes)
          .map((raw) => MessageReader.deserialize(raw, options));

  /// Like [deserializeStream] but yields the raw framed bytes for each message
  /// instead of a parsed [MessageReader].  Useful when the caller needs both
  /// the parsed content and the original bytes (e.g., to echo them back in an
  /// Unimplemented response).
  static Stream<Uint8List> deserializeStreamRaw(
    Stream<Uint8List> bytes,
  ) async* {
    final buffer = <int>[];

    await for (final chunk in bytes) {
      buffer.addAll(chunk);

      // Drain all complete messages from the buffer.
      while (true) {
        // Need at least 4 bytes to read (numSegments − 1).
        if (buffer.length < 4) break;

        final numSegments = _readUint32LE(buffer, 0) + 1;

        // Header size: (1 + numSegments) uint32s, padded to 8-byte boundary
        // when numSegments is even (so the count of uint32s is odd).
        final headerUint32s = 1 + numSegments + (numSegments.isEven ? 1 : 0);
        final headerBytes = headerUint32s * 4;

        if (buffer.length < headerBytes) break;

        // Sum segment sizes to find total message byte count.
        int totalDataBytes = 0;
        for (int i = 0; i < numSegments; i++) {
          totalDataBytes += _readUint32LE(buffer, (1 + i) * 4) * 8;
        }

        final totalBytes = headerBytes + totalDataBytes;
        if (buffer.length < totalBytes) break;

        final msgBytes = Uint8List.fromList(buffer.sublist(0, totalBytes));
        buffer.removeRange(0, totalBytes);

        yield msgBytes;
      }
    }

    if (buffer.isNotEmpty) {
      throw DecodeException(
          'stream ended with ${buffer.length} bytes of an incomplete message');
    }
  }

  /// Serializes a stream of [MessageBuilder]s into a stream of framed byte
  /// chunks, one [Uint8List] per message.
  static Stream<Uint8List> serializeStream(
    Stream<MessageBuilder> messages,
  ) async* {
    await for (final msg in messages) {
      yield msg.serialize();
    }
  }

  static int _readUint32LE(List<int> buf, int offset) =>
      buf[offset] |
      (buf[offset + 1] << 8) |
      (buf[offset + 2] << 16) |
      (buf[offset + 3] << 24);
}
