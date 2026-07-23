import 'dart:typed_data';

import '../wire/wire_helpers.dart';

/// A writable message segment that supports bump allocation.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class SegmentBuilder {
  final ByteData _data;
  bool _clearOnAllocate;
  int _usedWords;

  /// Holds the public [id] value.
  final int id;

  /// Creates a [SegmentBuilder] instance.
  SegmentBuilder(int initialWords, this.id)
    : _data = ByteData(initialWords * bytesPerWord),
      _clearOnAllocate = false,
      _usedWords = 0;

  /// Creates a segment pre-filled with [data], marked as fully used.
  /// Used by [ArenaBuilder.importSegmentData] to embed another message's segments.
  SegmentBuilder.fromData(Uint8List data, this.id)
    : _data = ByteData(data.lengthInBytes),
      _clearOnAllocate = false,
      _usedWords = data.lengthInBytes ~/ bytesPerWord {
    _data.buffer.asUint8List().setRange(0, data.lengthInBytes, data);
  }

  /// Creates a segment backed directly by externally-provided [scratch]
  /// memory, ready for bump allocation from word 0 — unlike [fromData], this
  /// starts empty rather than pre-filled/marked used. [scratch]'s length is
  /// truncated down to the nearest whole word if it isn't already
  /// word-aligned. Used by [ArenaBuilder.withScratchSpace] to avoid a fresh
  /// heap allocation for the first segment.
  SegmentBuilder.fromScratch(Uint8List scratch, this.id)
    : _data = ByteData.sublistView(
        scratch,
        0,
        (scratch.lengthInBytes ~/ bytesPerWord) * bytesPerWord,
      ),
      _clearOnAllocate = true,
      _usedWords = 0;

  /// Returns the current [capacity] value.
  int get capacity => _data.lengthInBytes ~/ bytesPerWord;

  /// Returns the current [usedWords] value.
  int get usedWords => _usedWords;

  /// Returns the current [data] value.
  ByteData get data => _data;

  /// Attempts to bump-allocate [words] words.
  /// Returns the word offset of the allocation, or null if the segment is full.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = builder.tryAllocate;
  /// ```
  int? tryAllocate(int words) {
    if (_usedWords + words > capacity) return null;
    final offset = _usedWords;
    _usedWords += words;
    if (_clearOnAllocate) {
      final allocatedBytes = _data.buffer.asUint8List(
        _data.offsetInBytes + offset * bytesPerWord,
        words * bytesPerWord,
      );
      allocatedBytes.fillRange(0, allocatedBytes.length, 0);
    }
    return offset;
  }

  /// The used portion of this segment as a ByteData view (no copy).
  ByteData get usedData =>
      ByteData.sublistView(_data, 0, _usedWords * bytesPerWord);

  /// Resets this segment to empty for reuse by a new message build cycle.
  ///
  /// Unlike a freshly allocated segment (whose backing [Uint8List] the Dart
  /// runtime already zero-initializes), this segment's bytes still hold
  /// content from its previous use — so [tryAllocate] must clear each newly
  /// claimed range on demand from now on (the same mechanism already used
  /// for externally-provided [fromScratch] memory), otherwise a field the
  /// next build leaves at its default (relying on the "unset == zero"
  /// convention) would silently read back the previous message's bytes at
  /// that offset instead.
  void reset() {
    _usedWords = 0;
    _clearOnAllocate = true;
  }
}
