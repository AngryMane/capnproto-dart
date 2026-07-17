import 'dart:convert';
import 'dart:typed_data';

import '../wire/pointer.dart';
import '../wire/wire_helpers.dart';
import 'segment_builder.dart';

/// Untyped view of a list's memory inside a writable segment, used by generated list builders.
class RawListBuilder {
  final SegmentBuilder segment;
  final ArenaBuilder arena;

  /// Byte offset within [segment] to the first element.
  final int dataByteOffset;
  final ListElementSize elementSize;
  final int elementCount;

  /// Per-element data words (composite lists only).
  final int structDataWords;

  /// Per-element pointer words (composite lists only).
  final int structPtrWords;

  const RawListBuilder({
    required this.segment,
    required this.arena,
    required this.dataByteOffset,
    required this.elementSize,
    required this.elementCount,
    this.structDataWords = 0,
    this.structPtrWords = 0,
  });
}

/// Untyped view of a struct's memory inside a writable segment, used by generated builders.
///
/// The data section occupies words `[dataWordOffset, dataWordOffset + dataWords)`.
/// The pointer section occupies words `[ptrWordOffset, ptrWordOffset + ptrWords)`.
class RawStructBuilder {
  final SegmentBuilder segment;
  final ArenaBuilder arena;
  final int dataWordOffset;
  final int dataWords;
  final int ptrWordOffset;
  final int ptrWords;

  const RawStructBuilder({
    required this.segment,
    required this.arena,
    required this.dataWordOffset,
    required this.dataWords,
    required this.ptrWordOffset,
    required this.ptrWords,
  });
}

/// Manages writable segments for a Cap'n Proto message under construction.
///
/// Uses bump allocation within segments. When the current segment is full,
/// a new segment is added automatically.
class ArenaBuilder {
  static const int _defaultSegmentWords = 1024; // 8 KiB

  final List<SegmentBuilder> _segments = [];

  ArenaBuilder([int initialCapacityWords = _defaultSegmentWords]) {
    _segments.add(SegmentBuilder(initialCapacityWords, 0));
  }

  /// Allocates [words] contiguous words, growing into a new segment if needed.
  /// Returns `(segment, wordOffset)`.
  (SegmentBuilder, int) allocate(int words) {
    final seg = _segments.last;
    final offset = seg.tryAllocate(words);
    if (offset != null) return (seg, offset);

    // Current segment is full: allocate a new one.
    final capacity =
        words > _defaultSegmentWords ? words * 2 : _defaultSegmentWords;
    final newSeg = SegmentBuilder(capacity, _segments.length);
    _segments.add(newSeg);
    return (newSeg, newSeg.tryAllocate(words)!);
  }

  SegmentBuilder getSegment(int id) => _segments[id];
  int get segmentCount => _segments.length;

  /// Imports a pre-built segment (e.g. from another message) into this arena.
  /// Returns the new segment ID.
  int importSegmentData(Uint8List data) {
    final seg = SegmentBuilder.fromData(data, _segments.length);
    _segments.add(seg);
    return seg.id;
  }

  /// Parses [messageBytes] as a standalone Cap'n Proto message, imports its
  /// segments into this arena, and writes a far pointer at [ptrWordOffset] in
  /// [ptrSeg] that points to the root of the imported segments.
  ///
  /// Only single-segment source messages are fully supported. Multi-segment
  /// messages are rejected with [UnsupportedError].
  void writeAnyPointerFromMessage(
    SegmentBuilder ptrSeg,
    int ptrWordOffset,
    Uint8List messageBytes,
  ) {
    if (messageBytes.lengthInBytes < 8) {
      throw ArgumentError(
        'message bytes too short to be a valid Cap\'n Proto message',
      );
    }
    final hdr = ByteData.sublistView(messageBytes, 0, 4);
    final numSegments = readUint32(hdr, 0) + 1;
    if (numSegments != 1) {
      throw UnsupportedError(
        'multi-segment AnyPointer embedding is not yet supported',
      );
    }
    final headerBytes =
        8; // for single segment: [numSegs-1, seg0Words] = 2 words
    final seg0Words = readUint32(ByteData.sublistView(messageBytes, 4, 8), 0);
    final seg0ByteCount = seg0Words * bytesPerWord;
    final seg0Data = messageBytes.buffer.asUint8List(
      messageBytes.offsetInBytes + headerBytes,
      seg0ByteCount,
    );

    // Import the params segment.  Word 0 of this segment is the original
    // message's root struct pointer, which becomes the landing pad for the
    // far pointer we write below.
    final importedSegId = importSegmentData(seg0Data);

    FarPointer(
      isDoubleFar: false,
      landingPadOffset: 0,
      segmentId: importedSegId,
    ).encode(ptrSeg.data, ptrWordOffset);
  }

  /// Serializes the message into a single [Uint8List] using Cap'n Proto framing.
  ///
  /// Framing format (little-endian):
  /// ```
  ///   uint32  numSegments - 1
  ///   uint32  size of segment 0 in words  (repeat for each segment)
  ///   uint32  padding word (present when numSegments is even)
  ///   <segment 0 bytes> <segment 1 bytes> ...
  /// ```
  Uint8List serialize() {
    final numSegments = _segments.length;
    final headerBytes = (1 + numSegments + (numSegments.isEven ? 1 : 0)) * 4;

    var dataBytes = 0;
    for (final seg in _segments) {
      dataBytes += seg.usedWords * bytesPerWord;
    }

    final output = Uint8List(headerBytes + dataBytes);
    final hdr = ByteData.view(output.buffer);

    writeUint32(hdr, 0, numSegments - 1);
    for (var i = 0; i < numSegments; i++) {
      writeUint32(hdr, 4 + i * 4, _segments[i].usedWords);
    }
    // Padding word is automatically 0 (Uint8List is zero-initialized).

    var offset = headerBytes;
    for (final seg in _segments) {
      final used = seg.usedData;
      output.setRange(
        offset,
        offset + used.lengthInBytes,
        used.buffer.asUint8List(used.offsetInBytes, used.lengthInBytes),
      );
      offset += used.lengthInBytes;
    }

    return output;
  }

  /// Allocates and initialises a struct with the given layout.
  ///
  /// Tries to place the struct in the same segment as the pointer. If the
  /// current segment is full (or the pointer lives in an older segment),
  /// allocates `1 + totalWords` in a new segment: one landing-pad word
  /// followed by the struct data, and writes a single-far pointer.
  RawStructBuilder allocateStruct({
    required SegmentBuilder ptrSeg,
    required int ptrWordOffset,
    required int dataWords,
    required int ptrWords,
  }) {
    final totalWords = dataWords + ptrWords;

    if (totalWords == 0) {
      // Empty struct: leave the pointer slot as null (already zeroed).
      return RawStructBuilder(
        segment: ptrSeg,
        arena: this,
        dataWordOffset: 0,
        dataWords: 0,
        ptrWordOffset: 0,
        ptrWords: 0,
      );
    }

    // Try same-segment allocation when ptrSeg is the current (last) segment.
    if (_segments.last.id == ptrSeg.id) {
      final offset = ptrSeg.tryAllocate(totalWords);
      if (offset != null) {
        StructPointer(
          offset: offset - ptrWordOffset - 1,
          dataWords: dataWords,
          ptrWords: ptrWords,
        ).encode(ptrSeg.data, ptrWordOffset);

        return RawStructBuilder(
          segment: ptrSeg,
          arena: this,
          dataWordOffset: offset,
          dataWords: dataWords,
          ptrWordOffset: offset + dataWords,
          ptrWords: ptrWords,
        );
      }
    }

    // Cross-segment: allocate [landing pad][struct data] together so the
    // landing-pad word is always within the same allocation as the data.
    final (dataSeg, landingPadOffset) = allocate(1 + totalWords);
    final structStart = landingPadOffset + 1;

    FarPointer(
      isDoubleFar: false,
      landingPadOffset: landingPadOffset,
      segmentId: dataSeg.id,
    ).encode(ptrSeg.data, ptrWordOffset);

    StructPointer(
      offset: 0,
      dataWords: dataWords,
      ptrWords: ptrWords,
    ).encode(dataSeg.data, landingPadOffset);

    return RawStructBuilder(
      segment: dataSeg,
      arena: this,
      dataWordOffset: structStart,
      dataWords: dataWords,
      ptrWordOffset: structStart + dataWords,
      ptrWords: ptrWords,
    );
  }

  // ---- List allocation used by StructBuilder ----

  /// Allocates storage for a list with the given layout and writes the list
  /// pointer at [ptrWordOffset] in [ptrSeg].
  ///
  /// For composite lists ([ListElementSize.composite]) set [structDataWords]
  /// and [structPtrWords]; [elementCount] is then the number of struct elements.
  /// For all other element sizes, [structDataWords]/[structPtrWords] are ignored.
  RawListBuilder allocateList({
    required SegmentBuilder ptrSeg,
    required int ptrWordOffset,
    required ListElementSize elementSize,
    required int elementCount,
    int structDataWords = 0,
    int structPtrWords = 0,
  }) {
    final bool isComposite = elementSize == ListElementSize.composite;

    final int totalDataWords;
    final int listPointerCount; // elementCountOrWordCount in the list pointer
    if (isComposite) {
      totalDataWords = elementCount * (structDataWords + structPtrWords);
      listPointerCount = totalDataWords; // composite encodes word count
    } else {
      totalDataWords = listDataWordCount(elementSize, elementCount);
      listPointerCount = elementCount;
    }

    final tagWords = isComposite ? 1 : 0;
    final allocationWords = tagWords + totalDataWords;

    // Note: allocationWords == 0 (empty non-composite lists, and List(Void)
    // regardless of element count) is NOT special-cased here. tryAllocate(0)
    // still returns the current bump position without consuming capacity, so
    // it falls through the same-segment path below and gets a real (rather
    // than hardcoded-zero) offset. This matters for canonicalization:
    // capnp's reference implementation likewise still "allocates" zero-sized
    // objects at the current bump cursor, so a hardcoded offset of 0 would
    // produce non-canonical output whenever some other allocation already
    // advanced the cursor before this empty list was written.

    // Try same-segment allocation when ptrSeg is the current (last) segment.
    if (_segments.last.id == ptrSeg.id) {
      final offset = ptrSeg.tryAllocate(allocationWords);
      if (offset != null) {
        ListPointer(
          offset: offset - ptrWordOffset - 1,
          elementSize: elementSize,
          elementCountOrWordCount: listPointerCount,
        ).encode(ptrSeg.data, ptrWordOffset);

        final int dataByteOffset;
        if (isComposite) {
          _writeCompositeTag(
            ptrSeg.data,
            offset,
            elementCount,
            structDataWords,
            structPtrWords,
          );
          dataByteOffset = (offset + 1) * bytesPerWord;
        } else {
          dataByteOffset = offset * bytesPerWord;
        }

        return RawListBuilder(
          segment: ptrSeg,
          arena: this,
          dataByteOffset: dataByteOffset,
          elementSize: elementSize,
          elementCount: elementCount,
          structDataWords: structDataWords,
          structPtrWords: structPtrWords,
        );
      }
    }

    // Cross-segment: allocate [landing pad][tag?][list data] together.
    final (dataSeg, landingPadOffset) = allocate(1 + allocationWords);
    final listStartOffset = landingPadOffset + 1;

    FarPointer(
      isDoubleFar: false,
      landingPadOffset: landingPadOffset,
      segmentId: dataSeg.id,
    ).encode(ptrSeg.data, ptrWordOffset);

    ListPointer(
      offset: 0,
      elementSize: elementSize,
      elementCountOrWordCount: listPointerCount,
    ).encode(dataSeg.data, landingPadOffset);

    final int dataByteOffset;
    if (isComposite) {
      _writeCompositeTag(
        dataSeg.data,
        listStartOffset,
        elementCount,
        structDataWords,
        structPtrWords,
      );
      dataByteOffset = (listStartOffset + 1) * bytesPerWord;
    } else {
      dataByteOffset = listStartOffset * bytesPerWord;
    }

    return RawListBuilder(
      segment: dataSeg,
      arena: this,
      dataByteOffset: dataByteOffset,
      elementSize: elementSize,
      elementCount: elementCount,
      structDataWords: structDataWords,
      structPtrWords: structPtrWords,
    );
  }

  // Encodes the tag word for a composite list.
  // The tag uses struct-pointer format with bits[31:2] = elementCount.
  void _writeCompositeTag(
    ByteData data,
    int wordOffset,
    int elementCount,
    int structDataWords,
    int structPtrWords,
  ) {
    StructPointer(
      offset: elementCount, // "offset" field holds element count in tag words
      dataWords: structDataWords,
      ptrWords: structPtrWords,
    ).encode(data, wordOffset);
  }

  // ---- Pointer field write helpers used by StructBuilder ----

  /// Writes a Text (UTF-8 string) list pointer at [ptrWordOffset] in [ptrSeg].
  /// A null [value] leaves the pointer slot zeroed (null pointer).
  void writeTextField(SegmentBuilder ptrSeg, int ptrWordOffset, String? value) {
    if (value == null) return;
    _writeByteList(
      ptrSeg,
      ptrWordOffset,
      utf8.encode(value),
      includeNullTerminator: true,
    );
  }

  /// Writes a Data (raw bytes) list pointer at [ptrWordOffset] in [ptrSeg].
  /// A null [value] leaves the pointer slot zeroed (null pointer).
  void writeDataField(
    SegmentBuilder ptrSeg,
    int ptrWordOffset,
    Uint8List? value,
  ) {
    if (value == null) return;
    _writeByteList(ptrSeg, ptrWordOffset, value, includeNullTerminator: false);
  }

  void _writeByteList(
    SegmentBuilder ptrSeg,
    int ptrWordOffset,
    List<int> bytes, {
    required bool includeNullTerminator,
  }) {
    final elementCount = bytes.length + (includeNullTerminator ? 1 : 0);
    final wordCount = (elementCount + bytesPerWord - 1) ~/ bytesPerWord;

    // Note: wordCount == 0 (an explicitly-set empty Data field; Text always
    // has wordCount >= 1 for its null terminator) is deliberately not
    // special-cased — see the comment in allocateList about why a hardcoded
    // offset of 0 would be non-canonical.

    // Try same-segment allocation.
    if (_segments.last.id == ptrSeg.id) {
      final dataOffset = ptrSeg.tryAllocate(wordCount);
      if (dataOffset != null) {
        ListPointer(
          offset: dataOffset - ptrWordOffset - 1,
          elementSize: ListElementSize.byte,
          elementCountOrWordCount: elementCount,
        ).encode(ptrSeg.data, ptrWordOffset);

        final byteStart = dataOffset * bytesPerWord;
        for (var i = 0; i < bytes.length; i++) {
          writeUint8(ptrSeg.data, byteStart + i, bytes[i]);
        }
        return;
      }
    }

    // Cross-segment: allocate [landing pad][list data] together.
    final (dataSeg, landingPadOffset) = allocate(1 + wordCount);
    final listDataWordOffset = landingPadOffset + 1;

    FarPointer(
      isDoubleFar: false,
      landingPadOffset: landingPadOffset,
      segmentId: dataSeg.id,
    ).encode(ptrSeg.data, ptrWordOffset);

    ListPointer(
      offset: 0,
      elementSize: ListElementSize.byte,
      elementCountOrWordCount: elementCount,
    ).encode(dataSeg.data, landingPadOffset);

    final byteStart = listDataWordOffset * bytesPerWord;
    for (var i = 0; i < bytes.length; i++) {
      writeUint8(dataSeg.data, byteStart + i, bytes[i]);
    }
  }
}
