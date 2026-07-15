import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:capnproto_dart/src/message/message_reader.dart';
import 'package:capnproto_dart/src/message/message_reader_options.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Hand-written structs simulating generated code for layout tests.
// ---------------------------------------------------------------------------

// struct AllPrimitives {
//   boolVal     @0  :Bool;      bit 0
//   uint8Val    @1  :UInt8;     byte 1
//   uint16Val   @2  :UInt16;    byte 2
//   uint32Val   @3  :UInt32;    byte 4
//   uint64Val   @4  :UInt64;    byte 8  (word 1)
//   int8Val     @5  :Int8;      byte 17
//   int16Val    @6  :Int16;     byte 18
//   int32Val    @7  :Int32;     byte 20
//   int64Val    @8  :Int64;     byte 24  (word 3)
//   float32Val  @9  :Float32;   byte 32  (word 4)
//   float64Val  @10 :Float64;   byte 40  (word 5)
// }
// Layout: dataWords = 6, ptrWords = 0
class AllPrimitivesReader extends StructReader {
  AllPrimitivesReader(super.raw);

  bool get boolVal => getBoolField(0);
  int get uint8Val => getUint8Field(1);
  int get uint16Val => getUint16Field(2);
  int get uint32Val => getUint32Field(4);
  int get uint64Val => getUint64Field(8);
  int get int8Val => getInt8Field(17);
  int get int16Val => getInt16Field(18);
  int get int32Val => getInt32Field(20);
  int get int64Val => getInt64Field(24);
  double get float32Val => getFloat32Field(32);
  double get float64Val => getFloat64Field(40);

  // Fields with non-zero defaults
  bool get boolDef => getBoolField(7 * 8, defaultValue: true); // bit 56
  int get uint32Def => getUint32Field(4, defaultValue: 42);
  int get int32Def => getInt32Field(20, defaultValue: -1);
  double get float64Def => getFloat64Field(40, defaultValue: 1.5);
}

class AllPrimitivesBuilder extends StructBuilder {
  AllPrimitivesBuilder(super.raw);

  set boolVal(bool v) => setBoolField(0, v);
  set uint8Val(int v) => setUint8Field(1, v);
  set uint16Val(int v) => setUint16Field(2, v);
  set uint32Val(int v) => setUint32Field(4, v);
  set uint64Val(int v) => setUint64Field(8, v);
  set int8Val(int v) => setInt8Field(17, v);
  set int16Val(int v) => setInt16Field(18, v);
  set int32Val(int v) => setInt32Field(20, v);
  set int64Val(int v) => setInt64Field(24, v);
  set float32Val(double v) => setFloat32Field(32, v);
  set float64Val(double v) => setFloat64Field(40, v);

  set uint32Def(int v) => setUint32Field(4, v, defaultValue: 42);
  set int32Def(int v) => setInt32Field(20, v, defaultValue: -1);
  set float64Def(double v) => setFloat64Field(40, v, defaultValue: 1.5);

  @override
  AllPrimitivesReader asReader() => throw UnimplementedError();
}

class _AllPrimitivesFactory
    extends StructFactory<AllPrimitivesReader, AllPrimitivesBuilder> {
  @override
  int get dataWords => 6;
  @override
  int get ptrWords => 0;

  @override
  AllPrimitivesReader fromRawReader(RawStructReader raw) =>
      AllPrimitivesReader(raw);

  @override
  AllPrimitivesBuilder fromRawBuilder(RawStructBuilder raw) =>
      AllPrimitivesBuilder(raw);
}

final allPrimFactory = _AllPrimitivesFactory();

// ---------------------------------------------------------------------------
// struct WithPointers {
//   name   @0 :Text;
//   data   @1 :Data;
// }
// Layout: dataWords = 0, ptrWords = 2
// ---------------------------------------------------------------------------
class WithPointersReader extends StructReader {
  WithPointersReader(super.raw);

  String? get name => getTextField(0);
  Uint8List? get data => getDataField(1);
  bool get hasName => hasPointerField(0);
  bool get hasData => hasPointerField(1);
}

class WithPointersBuilder extends StructBuilder {
  WithPointersBuilder(super.raw);

  set name(String? v) => setTextField(0, v);
  set data(Uint8List? v) => setDataField(1, v);

  @override
  WithPointersReader asReader() => throw UnimplementedError();
}

class _WithPointersFactory
    extends StructFactory<WithPointersReader, WithPointersBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 2;

  @override
  WithPointersReader fromRawReader(RawStructReader raw) =>
      WithPointersReader(raw);

  @override
  WithPointersBuilder fromRawBuilder(RawStructBuilder raw) =>
      WithPointersBuilder(raw);
}

final withPtrsFactory = _WithPointersFactory();

// ---------------------------------------------------------------------------
// struct Outer { inner @0 :Inner; }
// struct Inner { value @0 :Int32; }
// ---------------------------------------------------------------------------
class InnerReader extends StructReader {
  InnerReader(super.raw);

  int get value => getInt32Field(0);
}

class InnerBuilder extends StructBuilder {
  InnerBuilder(super.raw);

  set value(int v) => setInt32Field(0, v);

  @override
  InnerReader asReader() => throw UnimplementedError();
}

class OuterReader extends StructReader {
  OuterReader(super.raw);

  InnerReader? get inner =>
      getStructFieldWith(0, (raw) => InnerReader(raw));
}

class OuterBuilder extends StructBuilder {
  OuterBuilder(super.raw);

  InnerBuilder initInner() =>
      initStructFieldWith(0, (raw) => InnerBuilder(raw), 1, 0);

  @override
  OuterReader asReader() => throw UnimplementedError();
}

class _InnerFactory extends StructFactory<InnerReader, InnerBuilder> {
  @override int get dataWords => 1;
  @override int get ptrWords => 0;
  @override InnerReader fromRawReader(RawStructReader raw) => InnerReader(raw);
  @override InnerBuilder fromRawBuilder(RawStructBuilder raw) => InnerBuilder(raw);
}

class _OuterFactory extends StructFactory<OuterReader, OuterBuilder> {
  @override int get dataWords => 0;
  @override int get ptrWords => 1;
  @override OuterReader fromRawReader(RawStructReader raw) => OuterReader(raw);
  @override OuterBuilder fromRawBuilder(RawStructBuilder raw) => OuterBuilder(raw);
}

final innerFactory = _InnerFactory();
final outerFactory = _OuterFactory();

// ---------------------------------------------------------------------------
// Helper: round-trip a message through serialize/deserialize.
// ---------------------------------------------------------------------------
T _roundTrip<R extends StructReader, B extends StructBuilder, T>(
  StructFactory<R, B> factory,
  void Function(B) build,
  T Function(R) read,
) {
  final msg = MessageBuilder();
  build(msg.initRoot(factory));
  final bytes = msg.serialize();
  final r = MessageReader.deserialize(bytes).getRoot(factory);
  return read(r);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('StructReader data section — primitive round-trips', () {
    test('Bool field', () {
      expect(
        _roundTrip(allPrimFactory, (b) => b.boolVal = true, (r) => r.boolVal),
        isTrue,
      );
      expect(
        _roundTrip(allPrimFactory, (b) => b.boolVal = false, (r) => r.boolVal),
        isFalse,
      );
    });

    test('UInt8 field', () {
      expect(
        _roundTrip(allPrimFactory, (b) => b.uint8Val = 255, (r) => r.uint8Val),
        equals(255),
      );
    });

    test('UInt16 field', () {
      expect(
        _roundTrip(
            allPrimFactory, (b) => b.uint16Val = 0xCAFE, (r) => r.uint16Val),
        equals(0xCAFE),
      );
    });

    test('UInt32 field', () {
      expect(
        _roundTrip(allPrimFactory, (b) => b.uint32Val = 0xDEADBEEF,
            (r) => r.uint32Val),
        equals(0xDEADBEEF),
      );
    });

    test('UInt64 field', () {
      expect(
        _roundTrip(allPrimFactory, (b) => b.uint64Val = 0x123456789ABCDEF0,
            (r) => r.uint64Val),
        equals(0x123456789ABCDEF0),
      );
    });

    test('Int8 field (negative)', () {
      expect(
        _roundTrip(allPrimFactory, (b) => b.int8Val = -1, (r) => r.int8Val),
        equals(-1),
      );
    });

    test('Int16 field', () {
      expect(
        _roundTrip(
            allPrimFactory, (b) => b.int16Val = -32768, (r) => r.int16Val),
        equals(-32768),
      );
    });

    test('Int32 field', () {
      expect(
        _roundTrip(
            allPrimFactory, (b) => b.int32Val = -42, (r) => r.int32Val),
        equals(-42),
      );
    });

    test('Int64 field', () {
      expect(
        _roundTrip(allPrimFactory, (b) => b.int64Val = -9007199254740992,
            (r) => r.int64Val),
        equals(-9007199254740992),
      );
    });

    test('Float32 field', () {
      expect(
        _roundTrip(
            allPrimFactory, (b) => b.float32Val = 3.14, (r) => r.float32Val),
        closeTo(3.14, 0.0001),
      );
    });

    test('Float64 field', () {
      expect(
        _roundTrip(allPrimFactory, (b) => b.float64Val = 2.718281828,
            (r) => r.float64Val),
        closeTo(2.718281828, 1e-9),
      );
    });
  });

  group('StructReader data section — default value masking', () {
    test('unset UInt32 with default returns default', () {
      // Nothing written for uint32Def; expect default = 42.
      expect(
        _roundTrip(allPrimFactory, (_) {}, (r) => r.uint32Def),
        equals(42),
      );
    });

    test('unset Int32 with default returns default', () {
      expect(
        _roundTrip(allPrimFactory, (_) {}, (r) => r.int32Def),
        equals(-1),
      );
    });

    test('unset Float64 with default returns default', () {
      expect(
        _roundTrip(allPrimFactory, (_) {}, (r) => r.float64Def),
        closeTo(1.5, 1e-10),
      );
    });

    test('set UInt32 equal to default stores zero in buffer', () {
      // value == default → XOR = 0 stored → XOR on read = default
      expect(
        _roundTrip(allPrimFactory, (b) => b.uint32Def = 42, (r) => r.uint32Def),
        equals(42),
      );
    });

    test('set UInt32 to value different from default', () {
      expect(
        _roundTrip(
            allPrimFactory, (b) => b.uint32Def = 7, (r) => r.uint32Def),
        equals(7),
      );
    });

    test('set Float64 to non-default value', () {
      expect(
        _roundTrip(allPrimFactory, (b) => b.float64Def = 3.0,
            (r) => r.float64Def),
        closeTo(3.0, 1e-10),
      );
    });
  });

  group('StructReader pointer section — Text fields', () {
    test('null text field returns null', () {
      expect(
        _roundTrip(withPtrsFactory, (_) {}, (r) => r.name),
        isNull,
      );
    });

    test('hasPointerField is false when unset', () {
      expect(
        _roundTrip(withPtrsFactory, (_) {}, (r) => r.hasName),
        isFalse,
      );
    });

    test('set and read text field', () {
      expect(
        _roundTrip(withPtrsFactory, (b) => b.name = 'hello', (r) => r.name),
        equals('hello'),
      );
    });

    test('hasPointerField is true after set', () {
      expect(
        _roundTrip(
            withPtrsFactory, (b) => b.name = 'hi', (r) => r.hasName),
        isTrue,
      );
    });

    test('empty string survives round-trip', () {
      expect(
        _roundTrip(withPtrsFactory, (b) => b.name = '', (r) => r.name),
        equals(''),
      );
    });

    test('Unicode text survives round-trip', () {
      const text = 'こんにちは 🎉';
      expect(
        _roundTrip(withPtrsFactory, (b) => b.name = text, (r) => r.name),
        equals(text),
      );
    });

    test('long text (>8 bytes) survives round-trip', () {
      final text = 'A' * 256;
      expect(
        _roundTrip(withPtrsFactory, (b) => b.name = text, (r) => r.name),
        equals(text),
      );
    });
  });

  group('StructReader pointer section — Data fields', () {
    test('null data field returns null', () {
      expect(
        _roundTrip(withPtrsFactory, (_) {}, (r) => r.data),
        isNull,
      );
    });

    test('hasPointerField is false for data when unset', () {
      expect(
        _roundTrip(withPtrsFactory, (_) {}, (r) => r.hasData),
        isFalse,
      );
    });

    test('set and read data field', () {
      final bytes = Uint8List.fromList([0, 1, 2, 3, 255]);
      expect(
        _roundTrip(withPtrsFactory, (b) => b.data = bytes, (r) => r.data),
        equals([0, 1, 2, 3, 255]),
      );
    });

    test('empty data list survives round-trip', () {
      final empty = Uint8List(0);
      expect(
        _roundTrip(withPtrsFactory, (b) => b.data = empty, (r) => r.data),
        equals(<int>[]),
      );
    });
  });

  group('StructReader pointer section — nested struct fields', () {
    test('unset nested struct returns null', () {
      expect(
        _roundTrip(outerFactory, (_) {}, (r) => r.inner),
        isNull,
      );
    });

    test('init and read nested struct value', () {
      expect(
        _roundTrip(
          outerFactory,
          (b) => b.initInner().value = 99,
          (r) => r.inner?.value,
        ),
        equals(99),
      );
    });

    test('nested struct default value is zero when not set', () {
      expect(
        _roundTrip(
          outerFactory,
          (b) => b.initInner(), // init but leave at 0
          (r) => r.inner?.value,
        ),
        equals(0),
      );
    });
  });

  group('StructReader bounds — field absent in older message', () {
    test('data field beyond dataWords returns default', () {
      // Build a message with dataWords = 1 (only the first word).
      final msg = MessageBuilder();
      msg.initRoot(innerFactory); // dataWords = 1, ptrWords = 0
      final bytes = msg.serialize();

      // Read it as AllPrimitives (dataWords = 6) — fields in words 1..5 are absent.
      final arena = ArenaReader.fromBytes(bytes, const MessageReaderOptions());
      final raw = arena.getRootRaw();
      // Manually wrap as AllPrimitivesReader (only dataWords=1 available).
      final reader = AllPrimitivesReader(raw);

      // Fields in words 1..5 should return their defaults.
      expect(reader.uint64Val, equals(0)); // word 1 — absent
      expect(reader.int64Val, equals(0)); // word 3 — absent
    });

    test('pointer field beyond ptrWords returns null', () {
      // Build a WithPointers message but read pointer index 5 (out of range).
      final msg = MessageBuilder();
      msg.initRoot(withPtrsFactory);
      final bytes = msg.serialize();
      final r = MessageReader.deserialize(bytes).getRoot(withPtrsFactory);

      // hasPointerField(5) should be false (ptrWords = 2, index 5 is out of range).
      expect(r.hasPointerField(5), isFalse);
    });
  });
}
