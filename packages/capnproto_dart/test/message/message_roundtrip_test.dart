import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:capnproto_dart/src/message/message_reader.dart';
import 'package:capnproto_dart/src/wire/wire_helpers.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Minimal hand-written reader/builder pair that simulates generated code.
//
// Schema (pseudo):
//   struct Point {
//     x @0 :Int32;   # data section, bytes 0..3
//     y @1 :Int32;   # data section, bytes 4..7
//   }
// Layout: dataWords = 1, ptrWords = 0
// ---------------------------------------------------------------------------

class PointReader extends StructReader {
  PointReader(super.raw);

  int get x => getInt32Field(0);
  int get y => getInt32Field(4);
}

class PointBuilder extends StructBuilder {
  PointBuilder(super.raw);

  set x(int v) => setInt32Field(0, v);
  set y(int v) => setInt32Field(4, v);

  @override
  PointReader asReader() => throw UnimplementedError(
      'asReader() not needed for round-trip test; use serialize() instead');
}

// ignore: non_constant_identifier_names
final pointFactory = _PointFactory();

class _PointFactory extends StructFactory<PointReader, PointBuilder> {
  @override
  int get dataWords => 1;
  @override
  int get ptrWords => 0;

  @override
  PointReader fromRawReader(RawStructReader raw) => PointReader(raw);

  @override
  PointBuilder fromRawBuilder(RawStructBuilder raw) => PointBuilder(raw);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MessageBuilder + MessageReader round-trip', () {
    test('write and read back a Point struct', () {
      // Build
      final builder = MessageBuilder();
      final point = builder.initRoot(pointFactory);
      point.x = 42;
      point.y = -7;

      // Serialize
      final bytes = builder.serialize();
      expect(bytes.lengthInBytes, greaterThan(0));

      // Deserialize
      final reader = MessageReader.deserialize(bytes);
      final read = reader.getRoot(pointFactory);

      expect(read.x, equals(42));
      expect(read.y, equals(-7));
    });

    test('zero-initialised struct reads back zeros', () {
      final builder = MessageBuilder();
      builder.initRoot(pointFactory); // fields left at 0

      final bytes = builder.serialize();
      final reader = MessageReader.deserialize(bytes);
      final read = reader.getRoot(pointFactory);

      expect(read.x, equals(0));
      expect(read.y, equals(0));
    });

    test('negative values survive the round-trip', () {
      final builder = MessageBuilder();
      final point = builder.initRoot(pointFactory);
      point.x = -2147483648; // min int32
      point.y = 2147483647; // max int32

      final bytes = builder.serialize();
      final read = MessageReader.deserialize(bytes).getRoot(pointFactory);

      expect(read.x, equals(-2147483648));
      expect(read.y, equals(2147483647));
    });

    test('framing header is word-aligned (single segment, 8-byte header)', () {
      final builder = MessageBuilder();
      builder.initRoot(pointFactory);
      final bytes = builder.serialize();

      // Single segment: header = [numSegs-1 (uint32), seg0Size (uint32)] = 8 bytes.
      expect(bytes.lengthInBytes % bytesPerWord, equals(0));
    });
  });

  group('MessageBuilder.withScratchSpace', () {
    test('writes go directly into the caller\'s buffer and round-trip', () {
      final scratch = Uint8List(16 * bytesPerWord);
      final builder = MessageBuilder.withScratchSpace(scratch);
      final point = builder.initRoot(pointFactory);
      point.x = 42;
      point.y = -7;

      // Proof the write really landed in the caller's buffer: the root
      // pointer (word 0) and the struct's data (word 1, right after it)
      // are both non-zero somewhere in `scratch` before serialize() is
      // ever called.
      final view = ByteData.sublistView(scratch);
      var sawNonZero = false;
      for (var i = 0; i < scratch.length; i++) {
        if (scratch[i] != 0) {
          sawNonZero = true;
          break;
        }
      }
      expect(sawNonZero, isTrue);
      // Word 0 holds the root struct pointer; the struct's own data word
      // (dataWords=1, ptrWords=0) follows immediately at word 1.
      expect(view.getInt32(bytesPerWord, Endian.little), equals(42));
      expect(view.getInt32(bytesPerWord + 4, Endian.little), equals(-7));

      final bytes = builder.serialize();
      final read = MessageReader.deserialize(bytes).getRoot(pointFactory);
      expect(read.x, equals(42));
      expect(read.y, equals(-7));
    });

    test('a message larger than the scratch space still serializes correctly', () {
      // Only 2 words: root pointer (1 word) + nothing else — Point's 1 data
      // word can't fit alongside it, forcing an overflow into a second,
      // heap-allocated segment (exercised via a far pointer).
      final scratch = Uint8List(2 * bytesPerWord);
      final builder = MessageBuilder.withScratchSpace(scratch);
      final point = builder.initRoot(pointFactory);
      point.x = 1;
      point.y = 2;

      final bytes = builder.serialize();
      final read = MessageReader.deserialize(bytes).getRoot(pointFactory);
      expect(read.x, equals(1));
      expect(read.y, equals(2));
    });

    test('an empty scratch buffer falls back to a heap segment entirely', () {
      final builder = MessageBuilder.withScratchSpace(Uint8List(0));
      final point = builder.initRoot(pointFactory);
      point.x = 5;
      point.y = 6;

      final bytes = builder.serialize();
      final read = MessageReader.deserialize(bytes).getRoot(pointFactory);
      expect(read.x, equals(5));
      expect(read.y, equals(6));
    });
  });
}
