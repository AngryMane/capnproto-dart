import 'dart:convert';
import 'dart:typed_data';

import '../exception/decode_exception.dart';
import '../message/message_reader_options.dart';
import '../wire/pointer.dart';
import '../wire/wire_helpers.dart';
import 'arena_builder.dart' show ArenaBuilder;
import 'segment_reader.dart';

/// Untyped view of a list's memory inside a segment, used by generated list readers.
///
/// For non-composite lists, [dataByteOffset] points to the first element byte
/// and the stride is determined by [elementSize].
/// For composite lists, [dataByteOffset] points to the first element (after the
/// tag word) and each element spans [structDataWords] + [structPtrWords] words.
class RawListReader {
  final SegmentReader segment;
  final ArenaReader arena;

  /// Byte offset within [segment] to the first element (or first element byte).
  final int dataByteOffset;
  final ListElementSize elementSize;
  final int elementCount;
  final int nestingLimit;

  /// Per-element data words (composite lists only).
  final int structDataWords;

  /// Per-element pointer words (composite lists only).
  final int structPtrWords;

  const RawListReader({
    required this.segment,
    required this.arena,
    required this.dataByteOffset,
    required this.elementSize,
    required this.elementCount,
    required this.nestingLimit,
    this.structDataWords = 0,
    this.structPtrWords = 0,
  });
}

/// Untyped view of a struct's memory inside a segment, used by generated readers.
///
/// The data section occupies words `[dataWordOffset, dataWordOffset + dataWords)`.
/// The pointer section occupies words `[ptrWordOffset, ptrWordOffset + ptrWords)`.
class RawStructReader {
  final SegmentReader segment;
  final ArenaReader arena;
  final int dataWordOffset;
  final int dataWords;
  final int ptrWordOffset;
  final int ptrWords;
  final int nestingLimit;

  const RawStructReader({
    required this.segment,
    required this.arena,
    required this.dataWordOffset,
    required this.dataWords,
    required this.ptrWordOffset,
    required this.ptrWords,
    required this.nestingLimit,
  });
}

/// Manages the readable segments of a Cap'n Proto message and enforces
/// the traversal limit and nesting limit defined in [MessageReaderOptions].
class ArenaReader {
  final List<SegmentReader> _segments;
  final MessageReaderOptions _options;
  int _remainingTraversalWords;

  ArenaReader(this._segments, this._options)
      : _remainingTraversalWords = _options.traversalLimitInWords;

  int get nestingLimit => _options.nestingLimit;

  SegmentReader getSegment(int id) {
    if (id < 0 || id >= _segments.length) {
      throw DecodeException(
          'segment $id out of range (have ${_segments.length})');
    }
    return _segments[id];
  }

  void chargeTraversal(int words) {
    _remainingTraversalWords -= words;
    if (_remainingTraversalWords < 0) {
      throw DecodeException('traversal limit exceeded');
    }
  }

  /// Resolves the root struct pointer at word 0 of segment 0.
  RawStructReader getRootRaw() {
    final seg = getSegment(0);
    if (seg.wordCount < 1) {
      throw DecodeException('message too small to contain root pointer');
    }
    return _resolveStructAt(seg, 0, nestingLimit);
  }

  /// Resolves a struct pointer located at [wordOffset] within [segment].
  RawStructReader resolveStructAt(
    SegmentReader segment,
    int wordOffset,
    int nestingLimit,
  ) =>
      _resolveStructAt(segment, wordOffset, nestingLimit);

  RawStructReader _resolveStructAt(
    SegmentReader seg,
    int wordOffset,
    int nestingLimit,
  ) {
    if (nestingLimit <= 0) throw DecodeException('nesting limit exceeded');

    final ptr = WirePointer.decode(seg.data, wordOffset);

    if (ptr is NullPointer) {
      // A null pointer represents an empty struct (0 data words, 0 ptr words).
      // The segment reference is unused because no bytes will be read.
      return RawStructReader(
        segment: seg,
        arena: this,
        dataWordOffset: 0,
        dataWords: 0,
        ptrWordOffset: 0,
        ptrWords: 0,
        nestingLimit: nestingLimit - 1,
      );
    }

    if (ptr is FarPointer) return _resolveFarStruct(ptr, nestingLimit);

    if (ptr is StructPointer) {
      return _buildStructReader(seg, wordOffset, ptr, nestingLimit);
    }

    throw DecodeException(
        'expected struct pointer, got ${ptr.runtimeType}');
  }

  RawStructReader _buildStructReader(
    SegmentReader seg,
    int ptrWordOffset,
    StructPointer ptr,
    int nestingLimit,
  ) {
    final dataWordOffset = ptrWordOffset + 1 + ptr.offset;
    final dataWords = ptr.dataWords;
    final ptrWords = ptr.ptrWords;

    if (!seg.containsInterval(dataWordOffset, dataWords + ptrWords)) {
      throw DecodeException('struct out of segment bounds');
    }
    chargeTraversal(dataWords + ptrWords);

    return RawStructReader(
      segment: seg,
      arena: this,
      dataWordOffset: dataWordOffset,
      dataWords: dataWords,
      ptrWordOffset: dataWordOffset + dataWords,
      ptrWords: ptrWords,
      nestingLimit: nestingLimit - 1,
    );
  }

  RawStructReader _resolveFarStruct(FarPointer far, int nestingLimit) {
    final targetSeg = getSegment(far.segmentId);

    if (!far.isDoubleFar) {
      // Single-far: landing pad word is a regular pointer.
      if (!targetSeg.containsInterval(far.landingPadOffset, 1)) {
        throw DecodeException('far pointer landing pad out of bounds');
      }
      return _resolveStructAt(targetSeg, far.landingPadOffset, nestingLimit);
    }

    // Double-far: two-word landing pad.
    if (!targetSeg.containsInterval(far.landingPadOffset, 2)) {
      throw DecodeException('double-far landing pad out of bounds');
    }
    final inner = WirePointer.decode(targetSeg.data, far.landingPadOffset);
    if (inner is! FarPointer || inner.isDoubleFar) {
      throw DecodeException('invalid double-far inner pointer');
    }
    final tag = WirePointer.decode(targetSeg.data, far.landingPadOffset + 1);
    if (tag is! StructPointer) {
      throw DecodeException('invalid double-far tag');
    }
    final dataSeg = getSegment(inner.segmentId);
    final dataWordOffset = inner.landingPadOffset;
    if (!dataSeg.containsInterval(dataWordOffset, tag.dataWords + tag.ptrWords)) {
      throw DecodeException('double-far data out of bounds');
    }
    chargeTraversal(tag.dataWords + tag.ptrWords);

    return RawStructReader(
      segment: dataSeg,
      arena: this,
      dataWordOffset: dataWordOffset,
      dataWords: tag.dataWords,
      ptrWordOffset: dataWordOffset + tag.dataWords,
      ptrWords: tag.ptrWords,
      nestingLimit: nestingLimit - 1,
    );
  }

  // ---- List pointer resolution used by StructReader ----

  /// Resolves a list pointer at [wordOffset] in [seg].
  /// Returns null for a null pointer; throws [DecodeException] for malformed data.
  RawListReader? resolveListAt(
    SegmentReader seg,
    int wordOffset,
    int nestingLimit,
  ) {
    final ptr = WirePointer.decode(seg.data, wordOffset);
    if (ptr is NullPointer) return null;
    return _resolveListPointerAt(seg, wordOffset, ptr, nestingLimit);
  }

  RawListReader _resolveListPointerAt(
    SegmentReader seg,
    int wordOffset,
    WirePointer ptr,
    int nestingLimit,
  ) {
    if (nestingLimit <= 0) throw DecodeException('nesting limit exceeded');

    if (ptr is FarPointer) {
      final targetSeg = getSegment(ptr.segmentId);
      if (!ptr.isDoubleFar) {
        if (!targetSeg.containsInterval(ptr.landingPadOffset, 1)) {
          throw DecodeException('far pointer landing pad out of bounds');
        }
        final inner = WirePointer.decode(targetSeg.data, ptr.landingPadOffset);
        return _resolveListPointerAt(
            targetSeg, ptr.landingPadOffset, inner, nestingLimit);
      }
      // Double-far: two-word landing pad.
      if (!targetSeg.containsInterval(ptr.landingPadOffset, 2)) {
        throw DecodeException('double-far landing pad out of bounds');
      }
      final inner = WirePointer.decode(targetSeg.data, ptr.landingPadOffset);
      if (inner is! FarPointer || inner.isDoubleFar) {
        throw DecodeException('invalid double-far inner pointer');
      }
      final tag = WirePointer.decode(targetSeg.data, ptr.landingPadOffset + 1);
      if (tag is! ListPointer) {
        throw DecodeException('double-far tag is not a list pointer');
      }
      final dataSeg = getSegment(inner.segmentId);
      return _buildListReaderDirect(dataSeg, inner.landingPadOffset, tag, nestingLimit);
    }

    if (ptr is! ListPointer) {
      throw DecodeException(
          'expected list pointer, got ${ptr.runtimeType}');
    }

    return _buildListReaderDirect(
        seg, wordOffset + 1 + ptr.offset, ptr, nestingLimit);
  }

  /// Builds a [RawListReader] given a segment, the word offset of the first
  /// element (for composite: word offset of the tag word), and a list pointer
  /// tag that describes element size and count.
  RawListReader _buildListReaderDirect(
    SegmentReader dataSeg,
    int dataWordOffset,
    ListPointer ptr,
    int nestingLimit,
  ) {
    if (ptr.elementSize == ListElementSize.composite) {
      final totalWords = ptr.elementCountOrWordCount;
      // +1 for the tag word that precedes element data.
      if (!dataSeg.containsInterval(dataWordOffset, 1 + totalWords)) {
        throw DecodeException('composite list out of segment bounds');
      }
      chargeTraversal(1 + totalWords);

      // Tag word: struct-pointer format with "offset" field = element count.
      final tagLo = readUint32(dataSeg.data, dataWordOffset * bytesPerWord);
      final tagHi = readUint32(dataSeg.data, dataWordOffset * bytesPerWord + 4);
      if ((tagLo & 3) != 0) {
        throw DecodeException('invalid composite list tag word');
      }
      final elementCount = tagLo >> 2; // unsigned 30-bit count
      final structDataWords = tagHi & 0xFFFF;
      final structPtrWords = (tagHi >> 16) & 0xFFFF;

      // Verify tag layout is consistent with the declared total word count.
      // elementCount × (dataWords + ptrWords) must equal totalWords exactly;
      // any mismatch means elements would be read outside the checked region.
      final wordsPerElement = structDataWords + structPtrWords;
      if (elementCount * wordsPerElement != totalWords) {
        throw DecodeException(
            'composite list tag mismatch: declared $totalWords words but '
            'tag implies ${elementCount * wordsPerElement} '
            '($elementCount elements × $wordsPerElement words/element)');
      }

      return RawListReader(
        segment: dataSeg,
        arena: this,
        dataByteOffset: (dataWordOffset + 1) * bytesPerWord,
        elementSize: ListElementSize.composite,
        elementCount: elementCount,
        nestingLimit: nestingLimit - 1,
        structDataWords: structDataWords,
        structPtrWords: structPtrWords,
      );
    }

    // Non-composite list.
    final elementCount = ptr.elementCountOrWordCount;
    final wordCount = listDataWordCount(ptr.elementSize, elementCount);

    if (wordCount > 0 && !dataSeg.containsInterval(dataWordOffset, wordCount)) {
      throw DecodeException('list data out of segment bounds');
    }
    chargeTraversal(wordCount == 0 ? 1 : wordCount);

    return RawListReader(
      segment: dataSeg,
      arena: this,
      dataByteOffset: dataWordOffset * bytesPerWord,
      elementSize: ptr.elementSize,
      elementCount: elementCount,
      nestingLimit: nestingLimit - 1,
    );
  }

  // ---- Pointer field resolution helpers used by StructReader ----

  /// Resolves a struct pointer at [wordOffset] in [segment].
  /// Returns null when the pointer is null; throws for malformed pointers.
  RawStructReader? resolveOptionalStructAt(
    SegmentReader segment,
    int wordOffset,
    int nestingLimit,
  ) {
    final ptr = WirePointer.decode(segment.data, wordOffset);
    if (ptr is NullPointer) return null;
    return _resolveStructAt(segment, wordOffset, nestingLimit);
  }

  /// Reads a Text (UTF-8 string) from a byte-list pointer at [wordOffset].
  /// Returns null for a null pointer.
  ///
  /// Throws [DecodeException] if the Cap'n Proto Text invariants are violated:
  /// - `elementCount` must be >= 1 (every Text value has at least a NUL byte).
  /// - The last byte must be `0x00` (NUL terminator).
  ///
  /// Invalid UTF-8 sequences cause [utf8.decode] to throw a [FormatException].
  /// Callers that need lenient decoding can catch it and retry with
  /// `utf8.decode(bytes, allowMalformed: true)`.
  String? resolveTextAt(SegmentReader seg, int wordOffset) {
    final ptr = WirePointer.decode(seg.data, wordOffset);
    if (ptr is NullPointer) return null;
    final (listSeg, dataByteOffset, elementCount) =
        _resolveByteListPointer(seg, wordOffset, ptr);
    // The spec requires at least one byte: the NUL terminator.
    if (elementCount < 1) {
      throw DecodeException(
          'Text field has elementCount=$elementCount; must be >= 1');
    }
    // Validate the NUL terminator.
    final nulOffset = listSeg.data.offsetInBytes + dataByteOffset + elementCount - 1;
    if (listSeg.data.buffer.asUint8List()[nulOffset] != 0) {
      throw DecodeException('Text field is missing NUL terminator');
    }
    // Decode the content bytes (everything before the NUL).
    final bytes = Uint8List.view(
      listSeg.data.buffer,
      listSeg.data.offsetInBytes + dataByteOffset,
      elementCount - 1,
    );
    return utf8.decode(bytes);
  }

  /// Reads a Data (raw bytes) field from a byte-list pointer at [wordOffset].
  /// Returns null for a null pointer; returns a copy of the bytes.
  Uint8List? resolveDataAt(SegmentReader seg, int wordOffset) {
    final ptr = WirePointer.decode(seg.data, wordOffset);
    if (ptr is NullPointer) return null;
    final (listSeg, dataByteOffset, elementCount) =
        _resolveByteListPointer(seg, wordOffset, ptr);
    return Uint8List.fromList(Uint8List.view(
      listSeg.data.buffer,
      listSeg.data.offsetInBytes + dataByteOffset,
      elementCount,
    ));
  }

  (SegmentReader, int, int) _resolveByteListPointer(
    SegmentReader seg,
    int wordOffset,
    WirePointer ptr,
  ) {
    if (ptr is FarPointer) {
      final targetSeg = getSegment(ptr.segmentId);
      if (!ptr.isDoubleFar) {
        if (!targetSeg.containsInterval(ptr.landingPadOffset, 1)) {
          throw DecodeException('far pointer landing pad out of bounds');
        }
        final inner = WirePointer.decode(targetSeg.data, ptr.landingPadOffset);
        return _resolveByteListPointer(targetSeg, ptr.landingPadOffset, inner);
      }
      // Double-far: two-word landing pad.
      if (!targetSeg.containsInterval(ptr.landingPadOffset, 2)) {
        throw DecodeException('double-far landing pad out of bounds');
      }
      final inner = WirePointer.decode(targetSeg.data, ptr.landingPadOffset);
      if (inner is! FarPointer || inner.isDoubleFar) {
        throw DecodeException('invalid double-far inner pointer');
      }
      final tag = WirePointer.decode(targetSeg.data, ptr.landingPadOffset + 1);
      if (tag is! ListPointer) {
        throw DecodeException('double-far tag is not a list pointer');
      }
      final dataSeg = getSegment(inner.segmentId);
      return _buildByteListDirect(dataSeg, inner.landingPadOffset, tag);
    }

    if (ptr is ListPointer) {
      return _buildByteListDirect(seg, wordOffset + 1 + ptr.offset, ptr);
    }

    throw DecodeException(
        'expected list pointer for text/data, got ${ptr.runtimeType}');
  }

  /// Builds the (segment, byteOffset, elementCount) triple for a byte-list
  /// (Text or Data) given the segment and word offset where element data begins.
  (SegmentReader, int, int) _buildByteListDirect(
    SegmentReader dataSeg,
    int dataWordOffset,
    ListPointer ptr,
  ) {
    if (ptr.elementSize != ListElementSize.byte) {
      throw DecodeException(
          'expected byte list (text/data), got ${ptr.elementSize}');
    }
    final elementCount = ptr.elementCountOrWordCount;
    final wordCount = (elementCount + bytesPerWord - 1) ~/ bytesPerWord;

    chargeTraversal(wordCount == 0 ? 1 : wordCount);
    if (wordCount > 0 && !dataSeg.containsInterval(dataWordOffset, wordCount)) {
      throw DecodeException('list data out of segment bounds');
    }
    return (dataSeg, dataWordOffset * bytesPerWord, elementCount);
  }

  /// Parses the Cap'n Proto framing header and constructs an [ArenaReader].
  ///
  /// Framing format (little-endian):
  /// ```
  ///   uint32  numSegments - 1
  ///   uint32  size of segment 0 in words
  ///   uint32  size of segment 1 in words  (repeat for each segment)
  ///   uint32  padding word (present when numSegments is even)
  ///   <segment 0 bytes> <segment 1 bytes> ...
  /// ```
  static ArenaReader fromBytes(
    Uint8List bytes,
    MessageReaderOptions options,
  ) {
    if (bytes.lengthInBytes < 4) {
      throw DecodeException('message too short');
    }
    final numSegments = readUint32(ByteData.sublistView(bytes, 0, 4), 0) + 1;
    if (numSegments > options.maxSegments) {
      throw DecodeException(
        'message declares $numSegments segments, exceeding maxSegments '
        '(${options.maxSegments})',
      );
    }

    final minHeaderBytes = 4 + numSegments * 4;
    if (bytes.lengthInBytes < minHeaderBytes) {
      throw DecodeException('message header truncated');
    }

    final sizes = List.generate(
      numSegments,
      (i) => readUint32(ByteData.sublistView(bytes, 4 + i * 4, 8 + i * 4), 0),
    );

    // Padding is present when numSegments is even to keep the header word-aligned.
    final headerBytes = (1 + numSegments + (numSegments.isEven ? 1 : 0)) * 4;

    var offset = headerBytes;
    final segments = <SegmentReader>[];
    for (var i = 0; i < numSegments; i++) {
      final byteCount = sizes[i] * bytesPerWord;
      if (offset + byteCount > bytes.lengthInBytes) {
        throw DecodeException('segment $i data truncated');
      }
      segments.add(SegmentReader(
        ByteData.sublistView(bytes, offset, offset + byteCount),
        i,
      ));
      offset += byteCount;
    }

    return ArenaReader(segments, options);
  }

  /// Creates a **live-view** reader that shares the builder's buffer.
  ///
  /// The returned [ArenaReader] wraps the same segment data as [builder].
  /// Subsequent writes through the builder are immediately visible through
  /// the returned reader.
  ///
  /// If you need an immutable snapshot, serialize and deserialize instead:
  /// ```dart
  /// final snapshot = MessageReader.deserialize(messageBuilder.serialize());
  /// ```
  factory ArenaReader.fromBuilder(
    ArenaBuilder builder, [
    MessageReaderOptions options = const MessageReaderOptions(),
  ]) {
    final segs = <SegmentReader>[];
    for (int i = 0; i < builder.segmentCount; i++) {
      final seg = builder.getSegment(i);
      segs.add(SegmentReader(seg.usedData, seg.id));
    }
    return ArenaReader(segs, options);
  }
}
