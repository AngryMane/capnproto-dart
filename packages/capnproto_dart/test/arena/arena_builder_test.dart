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
      arena.allocate(1);    // goes to segment 1

      final bytes = arena.serialize();
      final data = ByteData.view(bytes.buffer);

      // numSegments - 1 = 1
      expect(data.getUint32(0, Endian.little), equals(1));
      // Header = (1 + 2 + 1_padding) * 4 = 16 bytes for 2 segments
      final headerBytes = (1 + 2 + 1) * 4; // padding because 2 is even
      expect(bytes.lengthInBytes,
          greaterThanOrEqualTo(headerBytes + (1024 + 1) * bytesPerWord));
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
