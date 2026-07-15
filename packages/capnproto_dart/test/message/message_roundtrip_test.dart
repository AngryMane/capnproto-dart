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
}
