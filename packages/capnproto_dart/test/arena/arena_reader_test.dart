import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/arena/segment_reader.dart';
import 'package:capnproto_dart/src/exception/decode_exception.dart';
import 'package:capnproto_dart/src/message/message_reader_options.dart';
import 'package:capnproto_dart/src/wire/pointer.dart';
import 'package:capnproto_dart/src/wire/wire_helpers.dart';
import 'package:test/test.dart';

// Builds a single-segment framed message containing [segmentWords] zeroed words
// of struct data, preceded by a root struct pointer.
Uint8List _buildMessage({
  required int dataWords,
  required int ptrWords,
  void Function(ByteData seg)? fillData,
}) {
  // Layout in segment:
  //   word 0 : root struct pointer
  //   words 1..1+dataWords+ptrWords : struct data
  final structWords = dataWords + ptrWords;
  final segWords = 1 + structWords;

  final seg = ByteData(segWords * bytesPerWord);
  // Write root struct pointer at word 0 (offset = 0 → struct starts at word 1)
  StructPointer(offset: 0, dataWords: dataWords, ptrWords: ptrWords)
      .encode(seg, 0);
  if (fillData != null) fillData(seg);

  // Framing: numSegments-1 (uint32) + segWords (uint32), no padding (1 segment = odd)
  final out = Uint8List(8 + segWords * bytesPerWord);
  final hdr = ByteData.view(out.buffer);
  writeUint32(hdr, 0, 0); // numSegments - 1 = 0
  writeUint32(hdr, 4, segWords);
  out.setRange(8, 8 + segWords * bytesPerWord,
      seg.buffer.asUint8List(0, segWords * bytesPerWord));
  return out;
}

void main() {
  group('ArenaReader.fromBytes', () {
    test('parses single-segment message', () {
      final bytes = _buildMessage(dataWords: 1, ptrWords: 0);
      final arena = ArenaReader.fromBytes(bytes, const MessageReaderOptions());
      expect(arena.getSegment(0).wordCount, equals(2)); // 1 ptr + 1 data
    });

    test('throws on too-short message', () {
      expect(
        () => ArenaReader.fromBytes(Uint8List(3), const MessageReaderOptions()),
        throwsA(isA<DecodeException>()),
      );
    });

    test('throws when segment data is truncated', () {
      // Header says 10 words but we only have 2 bytes of data.
      final bad = Uint8List(8 + 4); // header (8) + 4 bytes (not 10 words)
      final hdr = ByteData.view(bad.buffer);
      writeUint32(hdr, 0, 0); // 1 segment
      writeUint32(hdr, 4, 10); // 10 words — too large
      expect(
        () => ArenaReader.fromBytes(bad, const MessageReaderOptions()),
        throwsA(isA<DecodeException>()),
      );
    });

    test('parses two-segment message (with padding)', () {
      // Build a two-segment framed message.
      final seg0 = ByteData(1 * bytesPerWord); // 1 word (root pointer only)
      final seg1 = ByteData(2 * bytesPerWord); // 2 words of struct data
      // Root pointer in seg0 is a far pointer to seg1 word 0.
      FarPointer(isDoubleFar: false, landingPadOffset: 0, segmentId: 1)
          .encode(seg0, 0);
      // Landing pad in seg1 word 0: struct pointer with offset 0.
      StructPointer(offset: 0, dataWords: 1, ptrWords: 0).encode(seg1, 0);
      writeUint32(seg1, 1 * bytesPerWord, 0xCAFEBABE); // data in word 1

      // Framing: 2 segments → padding needed
      final headerBytes = (1 + 2 + 1) * 4; // 16 bytes
      final totalBytes =
          headerBytes + seg0.lengthInBytes + seg1.lengthInBytes;
      final out = Uint8List(totalBytes);
      final hdr = ByteData.view(out.buffer);
      writeUint32(hdr, 0, 1); // numSegments - 1 = 1
      writeUint32(hdr, 4, 1); // seg0: 1 word
      writeUint32(hdr, 8, 2); // seg1: 2 words
      // word at offset 12 = padding (stays 0)
      out.setRange(16, 16 + 8, seg0.buffer.asUint8List());
      out.setRange(24, 24 + 16, seg1.buffer.asUint8List());

      final arena = ArenaReader.fromBytes(out, const MessageReaderOptions());
      expect(arena.getSegment(0).wordCount, equals(1));
      expect(arena.getSegment(1).wordCount, equals(2));
    });
  });

  group('double-far pointer resolution', () {
    // Build a 3-segment message where the root struct's first pointer field
    // goes through a double-far pointer to a list/text/data in segment 2.
    //
    // Segment 0: [root struct ptr (dW=0, pW=1)] [double-far to seg1 word 0]
    // Segment 1: [single-far to seg2 word 0]    [list tag pointer]
    // Segment 2: <actual data>
    Uint8List buildDoubleFarMessage({
      required WirePointer listTag,
      required List<int> dataBytes,
    }) {
      final paddedLen = ((dataBytes.length + 7) ~/ bytesPerWord) * bytesPerWord;
      final paddedData = Uint8List(paddedLen)
        ..setRange(0, dataBytes.length, dataBytes);
      final dataWords = paddedLen ~/ bytesPerWord;

      // 3 segments (odd) → header is 4 + 3×4 = 16 bytes, no padding word.
      final out = Uint8List(16 + (2 + 2 + dataWords) * bytesPerWord);
      final bd = ByteData.view(out.buffer);

      // Header
      writeUint32(bd, 0, 2);          // numSegments - 1 = 2
      writeUint32(bd, 4, 2);          // seg0: 2 words
      writeUint32(bd, 8, 2);          // seg1: 2 words
      writeUint32(bd, 12, dataWords); // seg2

      // Segment 0
      final seg0 = ByteData.view(out.buffer, 16);
      StructPointer(offset: 0, dataWords: 0, ptrWords: 1).encode(seg0, 0);
      FarPointer(isDoubleFar: true, landingPadOffset: 0, segmentId: 1)
          .encode(seg0, 1);

      // Segment 1 (landing pad)
      final seg1 = ByteData.view(out.buffer, 16 + 2 * bytesPerWord);
      FarPointer(isDoubleFar: false, landingPadOffset: 0, segmentId: 2)
          .encode(seg1, 0);
      listTag.encode(seg1, 1);

      // Segment 2 (data)
      out.setRange(16 + 4 * bytesPerWord, 16 + 4 * bytesPerWord + paddedLen,
          paddedData);

      return out;
    }

    test('Text field via double-far pointer', () {
      final msg = buildDoubleFarMessage(
        listTag: ListPointer(
          offset: 0,
          elementSize: ListElementSize.byte,
          elementCountOrWordCount: 6, // "hello\0" = 6 bytes
        ),
        dataBytes: [0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x00], // "hello\0"
      );
      final arena = ArenaReader.fromBytes(msg, const MessageReaderOptions());
      final raw = arena.getRootRaw();
      final text = arena.resolveTextAt(raw.segment, raw.ptrWordOffset);
      expect(text, equals('hello'));
    });

    test('Data field via double-far pointer', () {
      final msg = buildDoubleFarMessage(
        listTag: ListPointer(
          offset: 0,
          elementSize: ListElementSize.byte,
          elementCountOrWordCount: 3,
        ),
        dataBytes: [0x01, 0x02, 0x03],
      );
      final arena = ArenaReader.fromBytes(msg, const MessageReaderOptions());
      final raw = arena.getRootRaw();
      final data = arena.resolveDataAt(raw.segment, raw.ptrWordOffset);
      expect(data, equals([0x01, 0x02, 0x03]));
    });

    test('uint32 List field via double-far pointer', () {
      final msg = buildDoubleFarMessage(
        listTag: ListPointer(
          offset: 0,
          elementSize: ListElementSize.fourBytes,
          elementCountOrWordCount: 3,
        ),
        dataBytes: [
          42, 0, 0, 0, // uint32 42
          100, 0, 0, 0, // uint32 100
          255, 0, 0, 0, // uint32 255
          0, 0, 0, 0, // padding to word boundary
        ],
      );
      final arena = ArenaReader.fromBytes(msg, const MessageReaderOptions());
      final raw = arena.getRootRaw();
      final list =
          arena.resolveListAt(raw.segment, raw.ptrWordOffset, arena.nestingLimit);
      expect(list, isNotNull);
      expect(list!.elementCount, equals(3));
      expect(list.elementSize, equals(ListElementSize.fourBytes));
      // Verify element data byte offsets point into segment 2.
      expect(list.dataByteOffset, equals(0)); // seg2 starts at offset 0
    });
  });

  group('ArenaReader.getRootRaw', () {
    test('resolves direct struct pointer', () {
      const dataWords = 2;
      const ptrWords = 1;
      final bytes = _buildMessage(dataWords: dataWords, ptrWords: ptrWords);
      final arena = ArenaReader.fromBytes(bytes, const MessageReaderOptions());
      final raw = arena.getRootRaw();
      expect(raw.dataWords, equals(dataWords));
      expect(raw.ptrWords, equals(ptrWords));
    });

    test('null root pointer returns empty struct', () {
      // Build a message with a zeroed root pointer slot (null pointer).
      final seg = ByteData(1 * bytesPerWord); // only the pointer word, all zeros
      final out = Uint8List(8 + 8);
      final hdr = ByteData.view(out.buffer);
      writeUint32(hdr, 0, 0);
      writeUint32(hdr, 4, 1);
      out.setRange(8, 16, seg.buffer.asUint8List());

      final arena = ArenaReader.fromBytes(out, const MessageReaderOptions());
      final raw = arena.getRootRaw();
      expect(raw.dataWords, equals(0));
      expect(raw.ptrWords, equals(0));
    });

    test('chargeTraversal enforces traversal limit', () {
      const opts = MessageReaderOptions(traversalLimitInWords: 1);
      // Message has 3 struct words → exceeds limit of 1.
      final bytes = _buildMessage(dataWords: 2, ptrWords: 1);
      final arena = ArenaReader.fromBytes(bytes, opts);
      expect(
        () => arena.getRootRaw(),
        throwsA(isA<DecodeException>()),
      );
    });

    test('nesting limit is decremented', () {
      final bytes = _buildMessage(dataWords: 1, ptrWords: 0);
      final arena = ArenaReader.fromBytes(bytes, const MessageReaderOptions());
      final raw = arena.getRootRaw();
      expect(raw.nestingLimit, equals(arena.nestingLimit - 1));
    });

    test('out-of-bounds struct pointer throws', () {
      // Root pointer claims struct at a word offset beyond the segment.
      final seg = ByteData(1 * bytesPerWord);
      // offset = 100 → struct starts at word 101, which is out of range.
      StructPointer(offset: 100, dataWords: 1, ptrWords: 0).encode(seg, 0);
      final out = Uint8List(8 + bytesPerWord);
      final hdr = ByteData.view(out.buffer);
      writeUint32(hdr, 0, 0);
      writeUint32(hdr, 4, 1);
      out.setRange(8, 16, seg.buffer.asUint8List());
      final arena = ArenaReader.fromBytes(out, const MessageReaderOptions());
      expect(() => arena.getRootRaw(), throwsA(isA<DecodeException>()));
    });

    test('out-of-range segment id throws', () {
      expect(
        () => ArenaReader(
          [SegmentReader(ByteData(8), 0)],
          const MessageReaderOptions(),
        ).getSegment(99),
        throwsA(isA<DecodeException>()),
      );
    });
  });
}
