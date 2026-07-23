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
///
/// **Intended users**
/// * Application and library developers working with Cap'n Proto messages.
///
/// **Primary use cases**
/// * Reads, writes, validates, or reports failures for application messages.
class MessageStream {
  const MessageStream._();

  /// Deserializes a stream of framed Cap'n Proto messages.
  ///
  /// Bytes may arrive in arbitrary chunk sizes; the implementation buffers
  /// internally and yields a [MessageReader] for each complete message.
  /// Throws [DecodeException] if the stream ends with a partial message.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = MessageStream.deserializeStream;
  /// ```
  static Stream<MessageReader> deserializeStream(
    Stream<Uint8List> bytes, [
    MessageReaderOptions options = const MessageReaderOptions(),

    ///
    /// **Example**
    /// ```dart
    /// // Given the required message, schema, or raw-layout values:
    /// final operation = MessageStream.deserializeStreamRaw;
    /// ```
  ]) => deserializeStreamRaw(
    bytes,
    options,
  ).map((raw) => MessageReader.deserialize(raw, options));

  /// Like [deserializeStream] but yields the raw framed bytes for each message
  /// instead of a parsed [MessageReader].  Useful when the caller needs both
  /// the parsed content and the original bytes (e.g., to echo them back in an
  /// Unimplemented response).
  ///
  /// [options] bounds how much a single declared message is allowed to make
  /// this method buffer *before* any of its content has actually arrived:
  /// [MessageReaderOptions.maxSegments] caps the declared segment count (read
  /// from the first 4 bytes alone) and [MessageReaderOptions.traversalLimitInWords]
  /// caps the declared total size, so a peer can't force unbounded buffering
  /// by framing a header that claims an enormous message.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = MessageStream.deserializeStreamRaw;
  /// ```
  static Stream<Uint8List> deserializeStreamRaw(
    Stream<Uint8List> bytes, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) async* {
    // A packed byte buffer, not a `List<int>` — a `List<int>` stores each
    // byte as a full boxed/SMI-tagged word rather than a single packed
    // byte, and `List.addAll`/`List.sublist` operate element-by-element
    // instead of via a bulk memory copy. Measured against a real socket
    // feeding many small chunks (see the RPC UDS benchmark), that made this
    // buffer the dominant cost for anything but the smallest messages —
    // several hundred times slower than the `Uint8List`-based approach
    // below for the same bytes.
    var buffer = Uint8List(0);
    // Valid bytes currently held are `buffer[0, bufferedLength)`; of those,
    // `buffer[0, consumed)` have already been yielded as part of a complete
    // message but not yet physically dropped. Compacted away once, right
    // before the next chunk is appended (below) — not with a shift per
    // drained message — so a chunk containing several complete messages
    // back-to-back (the common case for a busy stream) costs one O(buffered
    // bytes) shift total, not one per message.
    var bufferedLength = 0;
    var consumed = 0;

    await for (final chunk in bytes) {
      // Fast path: nothing left over from a previous chunk, and this chunk
      // is exactly one complete message — skip the accumulation buffer
      // entirely and hand back `chunk` itself instead of copying it in and
      // back out. Safe because `Stream<Uint8List>` sources (sockets,
      // WebSockets, StreamControllers) hand each event a distinct buffer
      // that they never mutate afterward — the same assumption every
      // caller of this method already relies on for chunks in general.
      if (bufferedLength == consumed) {
        final totalBytes = _tryMessageLength(chunk, 0, chunk.length, options);
        if (totalBytes == chunk.length) {
          bufferedLength = 0;
          consumed = 0;
          yield chunk;
          continue;
        }
      }

      if (consumed > 0) {
        final remaining = bufferedLength - consumed;
        buffer.setRange(0, remaining, buffer, consumed);
        bufferedLength = remaining;
        consumed = 0;
      }

      final neededLength = bufferedLength + chunk.length;
      if (neededLength > buffer.length) {
        // Doubling growth (like a typical growable-array strategy) keeps
        // repeated small appends to the same buffer amortized O(1), same as
        // `List<int>.addAll` would be — just without that type's per-byte
        // overhead.
        final grown = Uint8List(
          neededLength > buffer.length * 2 ? neededLength : buffer.length * 2,
        );
        grown.setRange(0, bufferedLength, buffer);
        buffer = grown;
      }
      buffer.setRange(bufferedLength, neededLength, chunk);
      bufferedLength = neededLength;

      // Drain all complete messages from the buffer.
      while (true) {
        final available = bufferedLength - consumed;
        final totalBytes = _tryMessageLength(
          buffer,
          consumed,
          available,
          options,
        );
        if (totalBytes == null) break;

        // `sublist` (unlike `sublistView`) copies, so the yielded message
        // stays valid after `buffer` is later compacted/grown/overwritten.
        final msgBytes = buffer.sublist(consumed, consumed + totalBytes);
        consumed += totalBytes;

        yield msgBytes;
      }
    }

    if (bufferedLength - consumed > 0) {
      throw DecodeException(
        'stream ended with ${bufferedLength - consumed} bytes of an '
        'incomplete message',
      );
    }
  }

  /// Like [deserializeStreamRaw], but for transports that already guarantee
  /// each stream event is exactly one complete framed message — for
  /// example, one Cap'n Proto message per WebSocket binary frame. Skips the
  /// accumulation buffer entirely instead of feeding every event through
  /// it, since there is never anything to reassemble across events.
  ///
  /// Throws [DecodeException] if an event is not exactly one complete,
  /// validly-framed message (too short, too long, or violating [options]'
  /// limits) — such an event means the transport didn't actually honor the
  /// one-message-per-event contract this method assumes, so it is treated
  /// as a protocol error rather than silently buffered/reassembled.
  static Stream<Uint8List> deserializeFramedStreamRaw(
    Stream<Uint8List> frames, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) async* {
    await for (final frame in frames) {
      final totalBytes = _tryMessageLength(frame, 0, frame.length, options);
      if (totalBytes != frame.length) {
        throw DecodeException(
          totalBytes == null
              ? 'framed message event of ${frame.length} bytes is shorter '
                  'than its declared header/message length'
              : 'framed message event of ${frame.length} bytes does not '
                  'match its declared message length of $totalBytes bytes',
        );
      }
      yield frame;
    }
  }

  /// Returns the total byte length of one complete message starting at
  /// [offset] in [buf], given [available] bytes from that offset, or `null`
  /// if [available] isn't yet enough to know. Throws [DecodeException] if
  /// the declared segment count or size exceeds [options]' limits.
  static int? _tryMessageLength(
    List<int> buf,
    int offset,
    int available,
    MessageReaderOptions options,
  ) {
    // Need at least 4 bytes to read (numSegments − 1).
    if (available < 4) return null;

    final numSegments = _readUint32LE(buf, offset) + 1;
    if (numSegments > options.maxSegments) {
      throw DecodeException(
        'message declares $numSegments segments, exceeding maxSegments '
        '(${options.maxSegments})',
      );
    }

    // Header size: (1 + numSegments) uint32s, padded to 8-byte boundary
    // when numSegments is even (so the count of uint32s is odd).
    final headerUint32s = 1 + numSegments + (numSegments.isEven ? 1 : 0);
    final headerBytes = headerUint32s * 4;

    if (available < headerBytes) return null;

    // Sum segment sizes to find total message byte count.
    int totalDataBytes = 0;
    for (int i = 0; i < numSegments; i++) {
      totalDataBytes += _readUint32LE(buf, offset + (1 + i) * 4) * 8;
    }
    if (totalDataBytes ~/ 8 > options.traversalLimitInWords) {
      throw DecodeException(
        'message declares ${totalDataBytes ~/ 8} words, exceeding '
        'traversalLimitInWords (${options.traversalLimitInWords})',
      );
    }

    final totalBytes = headerBytes + totalDataBytes;
    if (available < totalBytes) return null;
    return totalBytes;
  }

  /// Serializes a stream of [MessageBuilder]s into a stream of framed byte
  /// chunks, one [Uint8List] per message.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = MessageStream.serializeStream;
  /// ```
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
