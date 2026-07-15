import 'dart:typed_data';

import '../wire/wire_helpers.dart';

/// A writable message segment that supports bump allocation.
class SegmentBuilder {
  final ByteData _data;
  int _usedWords;
  final int id;

  SegmentBuilder(int initialWords, this.id)
      : _data = ByteData(initialWords * bytesPerWord),
        _usedWords = 0;

  /// Creates a segment pre-filled with [data], marked as fully used.
  /// Used by [ArenaBuilder.importSegmentData] to embed another message's segments.
  SegmentBuilder.fromData(Uint8List data, this.id)
      : _data = ByteData(data.lengthInBytes),
        _usedWords = data.lengthInBytes ~/ bytesPerWord {
    _data.buffer
        .asUint8List()
        .setRange(0, data.lengthInBytes, data);
  }

  int get capacity => _data.lengthInBytes ~/ bytesPerWord;
  int get usedWords => _usedWords;

  ByteData get data => _data;

  /// Attempts to bump-allocate [words] words.
  /// Returns the word offset of the allocation, or null if the segment is full.
  int? tryAllocate(int words) {
    if (_usedWords + words > capacity) return null;
    final offset = _usedWords;
    _usedWords += words;
    return offset;
  }

  /// The used portion of this segment as a ByteData view (no copy).
  ByteData get usedData =>
      ByteData.sublistView(_data, 0, _usedWords * bytesPerWord);
}
