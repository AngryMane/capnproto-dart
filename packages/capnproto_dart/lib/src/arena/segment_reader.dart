import 'dart:typed_data';

import '../wire/wire_helpers.dart';

/// An immutable, read-only view of one Cap'n Proto message segment.
class SegmentReader {
  final ByteData data;
  final int id;

  const SegmentReader(this.data, this.id);

  int get wordCount => data.lengthInBytes ~/ bytesPerWord;

  /// Returns true if the half-open interval [startWord, startWord + wordCount)
  /// lies entirely within this segment.
  bool containsInterval(int startWord, int wordCount) =>
      startWord >= 0 && startWord + wordCount <= this.wordCount;
}
