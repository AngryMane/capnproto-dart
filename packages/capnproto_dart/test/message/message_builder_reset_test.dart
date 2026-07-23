import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/arena/segment_builder.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:capnproto_dart/src/message/message_reader.dart';
import 'package:capnproto_dart/src/wire/wire_helpers.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Schema (pseudo):
//   struct Sample {
//     count @0 :Int32;   # data section, bytes 0..3
//     label @1 :Text;    # pointer section, ptr 0
//   }
// ---------------------------------------------------------------------------

class SampleReader extends StructReader {
  SampleReader(super.raw);
  int get count => getInt32Field(0);
  String? get label => getTextField(0);
}

class SampleBuilder extends StructBuilder {
  SampleBuilder(super.raw);
  set count(int v) => setInt32Field(0, v);
  set label(String? v) => setTextField(0, v);

  @override
  SampleReader asReader() => throw UnimplementedError();
}

class _SampleFactory extends StructFactory<SampleReader, SampleBuilder> {
  @override
  int get dataWords => 1;
  @override
  int get ptrWords => 1;

  @override
  SampleReader fromRawReader(RawStructReader raw) => SampleReader(raw);
  @override
  SampleBuilder fromRawBuilder(RawStructBuilder raw) => SampleBuilder(raw);
}

final sampleFactory = _SampleFactory();

void main() {
  group('MessageBuilder.reset', () {
    test('a reused builder round-trips correctly after reset', () {
      final message = MessageBuilder();
      final first = message.initRoot(sampleFactory);
      first.count = 42;
      first.label = 'first';
      final firstBytes = message.serialize();

      message.reset();

      final second = message.initRoot(sampleFactory);
      second.count = 7;
      second.label = 'second';
      final secondBytes = message.serialize();

      final firstRead = MessageReader.deserialize(
        firstBytes,
      ).getRoot(sampleFactory);
      expect(firstRead.count, equals(42));
      expect(firstRead.label, equals('first'));

      final secondRead = MessageReader.deserialize(
        secondBytes,
      ).getRoot(sampleFactory);
      expect(secondRead.count, equals(7));
      expect(secondRead.label, equals('second'));
    });

    test(
      'a field left unset after reset reads back as default, not the '
      'previous message\'s value (RUNTIME: reused-buffer zero-fill)',
      () {
        final message = MessageBuilder();
        final first = message.initRoot(sampleFactory);
        first.count = 999;
        first.label = 'stale value that must not leak';
        message.serialize();

        message.reset();

        // Deliberately leave both fields unset, relying on the
        // unset-field-reads-as-default convention — this is exactly the
        // case that breaks if reset() doesn't re-clear reused bytes.
        message.initRoot(sampleFactory);
        final bytes = message.serialize();

        final read = MessageReader.deserialize(bytes).getRoot(sampleFactory);
        expect(read.count, equals(0));
        expect(read.label, isNull);
      },
    );

    test('reset works when the message overflowed into extra segments, '
        'and reuse fits back in one segment', () {
      // A tiny initial segment (2 words: 1 for the root pointer, 1 for the
      // struct's data section) forces the Text field to overflow into a
      // second, heap-allocated segment via a far pointer.
      final message = MessageBuilder.withScratchSpace(Uint8List(2 * 8));
      final first = message.initRoot(sampleFactory);
      first.count = 1;
      first.label = 'this text does not fit in the scratch segment';
      final overflowedBytes = message.serialize();
      expect(
        MessageReader.deserialize(overflowedBytes).getRoot(sampleFactory).label,
        equals('this text does not fit in the scratch segment'),
      );

      message.reset();

      // A short label fits back in the single (reset) scratch segment.
      final second = message.initRoot(sampleFactory);
      second.count = 2;
      second.label = 'short';
      final bytes = message.serialize();

      final read = MessageReader.deserialize(bytes).getRoot(sampleFactory);
      expect(read.count, equals(2));
      expect(read.label, equals('short'));
    });

    test('reset works repeatedly across many cycles', () {
      final message = MessageBuilder();
      for (var i = 0; i < 1000; i++) {
        final root = message.initRoot(sampleFactory);
        root.count = i;
        root.label = 'message-$i';
        final bytes = message.serialize();
        final read = MessageReader.deserialize(bytes).getRoot(sampleFactory);
        expect(read.count, equals(i));
        expect(read.label, equals('message-$i'));
        message.reset();
      }
    });
  });

  group('ArenaBuilder.reset', () {
    test('discards every segment after the first', () {
      final arena = ArenaBuilder(2); // tiny: forces overflow quickly
      arena.allocate(1); // root pointer slot
      // Force growth into additional segments.
      arena.allocate(50);
      arena.allocate(50);
      expect(arena.segmentCount, greaterThan(1));

      arena.reset();

      expect(arena.segmentCount, equals(1));
    });

    test('the surviving segment is empty and re-clears on next allocation', () {
      final arena = ArenaBuilder(4);
      final (seg, offset) = arena.allocate(2);
      writeInt32(seg.data, offset * bytesPerWord, -1);
      expect(readInt32(seg.data, offset * bytesPerWord), equals(-1));

      arena.reset();

      final (seg2, offset2) = arena.allocate(2);
      // Same segment, same offset (bump pointer reset to 0) — but the
      // stale -1 from before reset must have been cleared, not left behind.
      expect(seg2.id, equals(0));
      expect(offset2, equals(0));
      expect(readInt32(seg2.data, offset2 * bytesPerWord), equals(0));
    });
  });

  group('SegmentBuilder.reset', () {
    test('usedWords returns to 0 and stale bytes are cleared on reuse', () {
      final seg = SegmentBuilder(4, 0);
      final offset = seg.tryAllocate(2)!;
      writeInt64(seg.data, offset * bytesPerWord, -1);
      expect(seg.usedWords, equals(2));

      seg.reset();
      expect(seg.usedWords, equals(0));

      final reusedOffset = seg.tryAllocate(2)!;
      expect(reusedOffset, equals(0));
      expect(readInt64(seg.data, reusedOffset * bytesPerWord), equals(0));
    });
  });
}
