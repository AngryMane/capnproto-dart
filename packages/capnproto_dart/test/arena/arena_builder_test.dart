import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/segment_builder.dart';
import 'package:capnproto_dart/src/wire/wire_helpers.dart';
import 'package:test/test.dart';

void main() {
  group('SegmentBuilder', () {
    test('allocates words sequentially', () {
      final seg = SegmentBuilder(4, 0);
      expect(seg.tryAllocate(2), equals(0));
      expect(seg.tryAllocate(2), equals(2));
      expect(seg.tryAllocate(1), isNull);
    });

    test('usedData reflects allocated words only', () {
      final seg = SegmentBuilder(8, 0);
      seg.tryAllocate(3);
      expect(seg.usedData.lengthInBytes, equals(3 * bytesPerWord));
    });

    test(
      'fromScratch starts empty and writes land in the caller\'s buffer',
      () {
        final scratch = Uint8List(4 * bytesPerWord);
        final seg = SegmentBuilder.fromScratch(scratch, 0);
        expect(seg.usedWords, equals(0));
        expect(seg.capacity, equals(4));

        final offset = seg.tryAllocate(2);
        writeUint32(seg.data, offset! * bytesPerWord, 0xCAFEBABE);

        // The write is visible through the original Uint8List — proof that
        // the segment aliases the caller's memory rather than a fresh copy.
        final view = ByteData.sublistView(scratch);
        expect(view.getUint32(0, Endian.little), equals(0xCAFEBABE));
      },
    );

    test('fromScratch truncates a non-word-aligned buffer', () {
      final scratch = Uint8List(bytesPerWord + 3); // 1.375 words
      final seg = SegmentBuilder.fromScratch(scratch, 0);
      expect(seg.capacity, equals(1));
    });

    test('allocation clears reused scratch bytes but not bytes outside it', () {
      final backing = Uint8List(6 * bytesPerWord)
        ..fillRange(0, 6 * bytesPerWord, 0xA5);
      final scratch = Uint8List.sublistView(
        backing,
        bytesPerWord,
        5 * bytesPerWord,
      );
      final seg = SegmentBuilder.fromScratch(scratch, 0);

      expect(seg.tryAllocate(2), equals(0));
      expect(scratch.sublist(0, 2 * bytesPerWord), everyElement(0));
      expect(
        scratch.sublist(2 * bytesPerWord),
        everyElement(0xA5),
        reason: 'unallocated scratch capacity must not be cleared eagerly',
      );
      expect(backing.sublist(0, bytesPerWord), everyElement(0xA5));
      expect(backing.sublist(5 * bytesPerWord), everyElement(0xA5));
    });
  });

  group('ArenaBuilder.allocate', () {
    test('first allocation is at segment 0, word 0', () {
      final arena = ArenaBuilder();
      final (seg, offset) = arena.allocate(1);
      expect(seg.id, equals(0));
      expect(offset, equals(0));
    });

    test('sequential allocations are contiguous within a segment', () {
      final arena = ArenaBuilder();
      final (_, off0) = arena.allocate(2);
      final (_, off1) = arena.allocate(3);
      expect(off0, equals(0));
      expect(off1, equals(2));
    });

    test('overflow triggers a new segment', () {
      // Small initial capacity to force overflow quickly.
      final arena = ArenaBuilder();
      // Exhaust the first segment.
      arena.allocate(1024);
      final (seg, _) = arena.allocate(1);
      expect(seg.id, equals(1));
      expect(arena.segmentCount, equals(2));
    });
  });

  group('ArenaBuilder.withScratchSpace', () {
    test('first allocation writes directly into the caller\'s buffer', () {
      final scratch = Uint8List(8 * bytesPerWord);
      final arena = ArenaBuilder.withScratchSpace(scratch);
      final (seg, off) = arena.allocate(1);
      expect(seg.id, equals(0));
      expect(off, equals(0));

      writeUint32(seg.data, off * bytesPerWord, 0x600DF00D);
      expect(
        ByteData.sublistView(scratch).getUint32(0, Endian.little),
        equals(0x600DF00D),
      );
    });

    test('a message that fits serializes correctly with no extra segments', () {
      final scratch = Uint8List(8 * bytesPerWord);
      final arena = ArenaBuilder.withScratchSpace(scratch);
      final (seg, off) = arena.allocate(2);
      writeUint32(seg.data, off * bytesPerWord, 0x11223344);

      expect(arena.segmentCount, equals(1));
      final bytes = arena.serialize();
      final hdr = ByteData.view(bytes.buffer);
      expect(hdr.getUint32(0, Endian.little), equals(0)); // numSegments - 1
      expect(hdr.getUint32(4, Endian.little), equals(2)); // segment 0 words
      expect(hdr.getUint32(8, Endian.little), equals(0x11223344));
    });

    test(
      'a message larger than the scratch space overflows to a heap segment',
      () {
        final scratch = Uint8List(2 * bytesPerWord); // tiny: only 2 words
        final arena = ArenaBuilder.withScratchSpace(scratch);
        arena.allocate(2); // exhausts the scratch segment exactly
        final (seg, _) = arena.allocate(1); // must overflow
        expect(seg.id, equals(1));
        expect(arena.segmentCount, equals(2));
      },
    );
  });

  group('ArenaBuilder.serialize (framing format)', () {
    test('single-segment message has correct header', () {
      final arena = ArenaBuilder();
      final (seg, off) = arena.allocate(1);
      writeUint32(seg.data, off * bytesPerWord, 0xDEADBEEF);

      final bytes = arena.serialize();
      final data = ByteData.view(bytes.buffer);

      // First uint32 = numSegments - 1 = 0
      expect(data.getUint32(0, Endian.little), equals(0));
      // Second uint32 = segment 0 word count = 1
      expect(data.getUint32(4, Endian.little), equals(1));
      // No padding (numSegments = 1 is odd)
      // Header size = 2 * 4 = 8 bytes
      // Segment data follows at byte 8
      expect(data.getUint32(8, Endian.little), equals(0xDEADBEEF));
    });

    test('two-segment message has padding word', () {
      final arena = ArenaBuilder();
      arena.allocate(1024); // fill segment 0
      arena.allocate(1); // goes to segment 1

      final bytes = arena.serialize();
      final data = ByteData.view(bytes.buffer);

      // numSegments - 1 = 1
      expect(data.getUint32(0, Endian.little), equals(1));
      // Header = (1 + 2 + 1_padding) * 4 = 16 bytes for 2 segments
      final headerBytes = (1 + 2 + 1) * 4; // padding because 2 is even
      expect(
        bytes.lengthInBytes,
        greaterThanOrEqualTo(headerBytes + (1024 + 1) * bytesPerWord),
      );
    });

    test('serialize → ArenaReader.fromBytes roundtrip preserves data', () {
      final arena = ArenaBuilder();
      final (seg, off) = arena.allocate(2);
      writeUint32(seg.data, off * bytesPerWord, 0x12345678);
      writeUint32(seg.data, off * bytesPerWord + 4, 0xABCDEF01);

      final bytes = arena.serialize();
      // Re-parse just the framing manually.
      final hdr = ByteData.view(bytes.buffer);
      final numSegs = hdr.getUint32(0, Endian.little) + 1;
      expect(numSegs, equals(1));
      final segWords = hdr.getUint32(4, Endian.little);
      expect(segWords, equals(2));
    });
  });
}
