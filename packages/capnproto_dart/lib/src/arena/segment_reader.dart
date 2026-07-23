import 'dart:typed_data';

import '../wire/wire_helpers.dart';

/// An immutable, read-only view of one Cap'n Proto message segment.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class SegmentReader {
  /// Holds the public [data] value.
  final ByteData data;

  /// Holds the public [id] value.
  final int id;

  /// Creates a [SegmentReader] instance.
  const SegmentReader(this.data, this.id);

  /// Returns the current [wordCount] value.
  int get wordCount => data.lengthInBytes ~/ bytesPerWord;

  /// Returns true if the half-open interval [startWord, startWord + wordCount)
  /// lies entirely within this segment.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.containsInterval;
  /// ```
  bool containsInterval(int startWord, int wordCount) =>
      startWord >= 0 && startWord + wordCount <= this.wordCount;
}
