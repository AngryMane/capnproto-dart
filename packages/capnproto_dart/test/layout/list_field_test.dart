import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/exception/decode_exception.dart';
import 'package:capnproto_dart/src/layout/any_pointer.dart';
import 'package:capnproto_dart/src/layout/list_builder.dart';
import 'package:capnproto_dart/src/layout/list_reader.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:capnproto_dart/src/message/message_reader.dart';
import 'package:capnproto_dart/src/wire/pointer.dart' show ListElementSize;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Hand-written structs simulating generated code.
//
// struct Container {
//   bools    @0  :List(Bool);
//   int32s   @1  :List(Int32);
//   uint64s  @2  :List(UInt64);
//   floats   @3  :List(Float64);
//   texts    @4  :List(Text);
//   dataList @5  :List(Data);
//   items    @6  :List(Item);
//   voids    @7  :List(Void);
// }
// Layout: dataWords=0, ptrWords=8
//
// struct Item { value @0 :Int32; label @1 :Text; }
// Layout: dataWords=1, ptrWords=1
// ---------------------------------------------------------------------------

class ItemReader extends StructReader {
  ItemReader(super.raw);
  int get value => getInt32Field(0);
  String? get label => getTextField(0);
}

class ItemBuilder extends StructBuilder {
  ItemBuilder(super.raw);
  set value(int v) => setInt32Field(0, v);
  set label(String? v) => setTextField(0, v);

  @override
  ItemReader asReader() => throw UnimplementedError();
}

class _ItemFactory extends StructFactory<ItemReader, ItemBuilder> {
  @override
  int get dataWords => 1;
  @override
  int get ptrWords => 1;
  @override
  ItemReader fromRawReader(RawStructReader r) => ItemReader(r);
  @override
  ItemBuilder fromRawBuilder(RawStructBuilder r) => ItemBuilder(r);
}

final itemFactory = _ItemFactory();

class ContainerReader extends StructReader {
  ContainerReader(super.raw);

  ListReader<bool>? get bools => getBoolListField(0);
  ListReader<int>? get int32s => getInt32ListField(1);
  ListReader<int>? get uint64s => getUint64ListField(2);
  ListReader<double>? get floats => getFloat64ListField(3);
  ListReader<String?>? get texts => getTextListField(4);
  ListReader<Uint8List?>? get dataList => getDataListField(5);
  ListReader<ItemReader>? get items =>
      getStructListFieldWith(6, (r) => ItemReader(r));
  ListReader<Null>? get voids => getVoidListField(7);
}

class ContainerBuilder extends StructBuilder {
  ContainerBuilder(super.raw);

  ListBuilder<bool> initBools(int n) => initBoolListField(0, n);
  ListBuilder<int> initInt32s(int n) => initInt32ListField(1, n);
  ListBuilder<int> initUint64s(int n) => initUint64ListField(2, n);
  ListBuilder<double> initFloats(int n) => initFloat64ListField(3, n);
  ListBuilder<String?> initTexts(int n) => initTextListField(4, n);
  ListBuilder<Uint8List?> initDataList(int n) => initDataListField(5, n);
  ListBuilder<ItemBuilder> initItems(int n) =>
      initStructListFieldWith(6, n, (r) => ItemBuilder(r), 1, 1);
  ListBuilder<Null> initVoids(int n) => initVoidListField(7, n);

  @override
  ContainerReader asReader() => throw UnimplementedError();
}

class _ContainerFactory
    extends StructFactory<ContainerReader, ContainerBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 8;
  @override
  ContainerReader fromRawReader(RawStructReader r) => ContainerReader(r);
  @override
  ContainerBuilder fromRawBuilder(RawStructBuilder r) => ContainerBuilder(r);
}

final containerFactory = _ContainerFactory();

class CapabilityListContainerReader extends StructReader {
  CapabilityListContainerReader(super.raw, {super.capabilities});

  ListReader<int>? get caps => getCapabilityListField(0);
  ListReader<String?>? get typedCaps =>
      getCapabilityListFieldWith<String>(0, (cap) => cap as String);
}

class CapabilityListContainerBuilder extends StructBuilder {
  CapabilityListContainerBuilder(super.raw);

  ListBuilder<int> initCaps(int n) => initCapabilityListField(0, n);

  @override
  CapabilityListContainerReader asReader() => throw UnimplementedError();
}

class _CapabilityListContainerFactory
    extends
        StructFactory<
          CapabilityListContainerReader,
          CapabilityListContainerBuilder
        > {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 1;
  @override
  CapabilityListContainerReader fromRawReader(RawStructReader r) =>
      CapabilityListContainerReader(r);
  @override
  CapabilityListContainerReader fromRawReaderWithCapabilities(
    RawStructReader r,
    List<Object?> capabilities,
  ) => CapabilityListContainerReader(r, capabilities: capabilities);
  @override
  CapabilityListContainerBuilder fromRawBuilder(RawStructBuilder r) =>
      CapabilityListContainerBuilder(r);
}

final capabilityListContainerFactory = _CapabilityListContainerFactory();

// ---------------------------------------------------------------------------
// Minimal struct with 1 pointer word, used by Dynamic API and capability tests.
// ---------------------------------------------------------------------------

class _OnePtrReader extends StructReader {
  _OnePtrReader(super.raw);
}

class _OnePtrBuilder extends StructBuilder {
  _OnePtrBuilder(super.raw);
  @override
  StructReader asReader() => throw UnimplementedError();
}

class _OnePtrFactory extends StructFactory<_OnePtrReader, _OnePtrBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 1;
  @override
  _OnePtrReader fromRawReader(RawStructReader r) => _OnePtrReader(r);
  @override
  _OnePtrBuilder fromRawBuilder(RawStructBuilder r) => _OnePtrBuilder(r);
}

final _onePtrFactory = _OnePtrFactory();

// ---------------------------------------------------------------------------
// Hand-written structs for nested list tests.
//
// struct NestedContainer {
//   rows      @0 :List(List(Float64));    # 2-level nesting
//   matrices  @1 :List(List(List(Int32))); # 3-level nesting
// }
// Layout: dataWords=0, ptrWords=2
// ---------------------------------------------------------------------------

class NestedContainerReader extends StructReader {
  NestedContainerReader(super.raw);

  ListReader<ListReader<double>?>? get rows =>
      getNestedListField(0, float64ListFromRaw);

  ListReader<ListReader<ListReader<int>?>?>? get matrices => getNestedListField(
    1,
    (raw) => NestedListReader<int>(raw, int32ListFromRaw),
  );
}

class NestedContainerBuilder extends StructBuilder {
  NestedContainerBuilder(super.raw);

  NestedListBuilder<ListBuilder<double>> initRows(int n) => initNestedListField(
    0,
    n,
    float64ListBuilderFromRaw,
    ListElementSize.eightBytes,
  );

  NestedListBuilder<NestedListBuilder<ListBuilder<int>>> initMatrices(int n) =>
      initBiNestedListField(
        1,
        n,
        int32ListBuilderFromRaw,
        ListElementSize.fourBytes,
      );

  @override
  NestedContainerReader asReader() => throw UnimplementedError();
}

class _NestedContainerFactory
    extends StructFactory<NestedContainerReader, NestedContainerBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 2;
  @override
  NestedContainerReader fromRawReader(RawStructReader r) =>
      NestedContainerReader(r);
  @override
  NestedContainerBuilder fromRawBuilder(RawStructBuilder r) =>
      NestedContainerBuilder(r);
}

final nestedContainerFactory = _NestedContainerFactory();

T _rtNested<T>(
  void Function(NestedContainerBuilder) build,
  T Function(NestedContainerReader) read,
) {
  final msg = MessageBuilder();
  build(msg.initRoot(nestedContainerFactory));
  final bytes = msg.serialize();
  return read(MessageReader.deserialize(bytes).getRoot(nestedContainerFactory));
}

// ---------------------------------------------------------------------------
// Helper: build → serialize → deserialize → inspect.
// ---------------------------------------------------------------------------
T _rt<T>(
  void Function(ContainerBuilder) build,
  T Function(ContainerReader) read,
) {
  final msg = MessageBuilder();
  build(msg.initRoot(containerFactory));
  final bytes = msg.serialize();
  return read(MessageReader.deserialize(bytes).getRoot(containerFactory));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  group('Null list pointers', () {
    test('unset list field returns null', () {
      expect(_rt((_) {}, (r) => r.int32s), isNull);
      expect(_rt((_) {}, (r) => r.texts), isNull);
      expect(_rt((_) {}, (r) => r.items), isNull);
    });
  });

  group('Capability list', () {
    test('unset element reads consistently from builder and reader', () {
      final msg = MessageBuilder();
      final root = msg.initRoot(capabilityListContainerFactory);
      final caps = root.initCaps(2);

      expect(caps[0], -1);
      caps[1] = 0;
      expect(caps[1], 0);

      final reader = MessageReader.deserialize(
        msg.serialize(),
      ).getRoot(capabilityListContainerFactory);
      expect(reader.caps![0], -1);
      expect(reader.caps![1], 0);
    });

    test('typed reader resolves capability pointers through cap table', () {
      final msg = MessageBuilder();
      final root = msg.initRoot(capabilityListContainerFactory);
      final caps = root.initCaps(2);
      caps[0] = 1;
      caps[1] = 0;

      final reader = MessageReader.deserialize(msg.serialize()).getRoot(
        capabilityListContainerFactory,
        capabilities: ['alpha', 'bravo'],
      );

      expect(reader.caps!.toList(), equals([1, 0]));
      expect(reader.typedCaps!.toList(), equals(['bravo', 'alpha']));
    });
  });

  group('Void list', () {
    test('non-empty List(Void) preserves count', () {
      final result = _rt((b) {
        final list = b.initVoids(4);
        expect(list.length, equals(4));
        expect(list[0], isNull);
      }, (r) => r.voids!.length);
      expect(result, equals(4));
    });

    test('empty List(Void) has length 0', () {
      expect(_rt((b) => b.initVoids(0), (r) => r.voids!.length), equals(0));
    });
  });

  group('Bool list', () {
    test('round-trip [true, false, true]', () {
      final result = _rt((b) {
        final list = b.initBools(3);
        list[0] = true;
        list[1] = false;
        list[2] = true;
      }, (r) => r.bools!.toList());
      expect(result, equals([true, false, true]));
    });

    test('all-true list with 65 elements (crosses word boundary)', () {
      final result = _rt((b) {
        final list = b.initBools(65);
        for (var i = 0; i < 65; i++) {
          list[i] = true;
        }
      }, (r) => r.bools!.toList());
      expect(result, everyElement(isTrue));
      expect(result.length, equals(65));
    });

    test('empty bool list has length 0', () {
      expect(_rt((b) => b.initBools(0), (r) => r.bools!.length), equals(0));
    });

    test('builder reads back written values', () {
      final msg = MessageBuilder();
      final list = msg.initRoot(containerFactory).initBools(4);
      list[0] = true;
      list[2] = true;
      expect(list[0], isTrue);
      expect(list[1], isFalse);
      expect(list[2], isTrue);
      expect(list[3], isFalse);
    });
  });

  group('Int32 list', () {
    test('round-trip [1, -2, 2147483647]', () {
      final result = _rt((b) {
        final list = b.initInt32s(3);
        list[0] = 1;
        list[1] = -2;
        list[2] = 2147483647;
      }, (r) => r.int32s!.toList());
      expect(result, equals([1, -2, 2147483647]));
    });

    test('length is correct', () {
      expect(_rt((b) => b.initInt32s(10), (r) => r.int32s!.length), equals(10));
    });

    test('iterable works', () {
      final sum = _rt((b) {
        final list = b.initInt32s(5);
        for (var i = 0; i < 5; i++) {
          list[i] = i + 1;
        }
      }, (r) => r.int32s!.fold<int>(0, (acc, v) => acc + v));
      expect(sum, equals(15));
    });
  });

  group('UInt64 list', () {
    test('round-trip large values', () {
      const v = 0x123456789ABCDEF0;
      final result = _rt((b) {
        final list = b.initUint64s(2);
        list[0] = v;
        list[1] = 0;
      }, (r) => r.uint64s!.toList());
      expect(result[0], equals(v));
      expect(result[1], equals(0));
    });
  });

  group('Float64 list', () {
    test('round-trip [3.14, -1.0, 0.0]', () {
      final result = _rt((b) {
        final list = b.initFloats(3);
        list[0] = 3.14;
        list[1] = -1.0;
        list[2] = 0.0;
      }, (r) => r.floats!.toList());
      expect(result[0], closeTo(3.14, 1e-10));
      expect(result[1], equals(-1.0));
      expect(result[2], equals(0.0));
    });
  });

  group('Text list', () {
    test('round-trip list of strings', () {
      final result = _rt((b) {
        final list = b.initTexts(3);
        list[0] = 'hello';
        list[1] = 'world';
        list[2] = null;
      }, (r) => r.texts!.toList());
      expect(result[0], equals('hello'));
      expect(result[1], equals('world'));
      expect(result[2], isNull);
    });

    test('empty text list has length 0', () {
      expect(_rt((b) => b.initTexts(0), (r) => r.texts!.length), equals(0));
    });

    test('unicode strings survive round-trip', () {
      const s = 'こんにちは 🎉';
      final result = _rt((b) {
        final list = b.initTexts(1);
        list[0] = s;
      }, (r) => r.texts![0]);
      expect(result, equals(s));
    });
  });

  group('Data list', () {
    test('round-trip list of byte arrays', () {
      final a = Uint8List.fromList([1, 2, 3]);
      final b2 = Uint8List.fromList([255, 0]);
      final result = _rt((b) {
        final list = b.initDataList(3);
        list[0] = a;
        list[1] = b2;
        list[2] = null;
      }, (r) => r.dataList!.toList());
      expect(result[0], equals([1, 2, 3]));
      expect(result[1], equals([255, 0]));
      expect(result[2], isNull);
    });
  });

  group('Composite struct list', () {
    test('round-trip list of Items', () {
      final result = _rt((b) {
        final items = b.initItems(3);
        items[0]
          ..value = 10
          ..label = 'ten';
        items[1]
          ..value = 20
          ..label = 'twenty';
        items[2]
          ..value = 30
          ..label = null;
      }, (r) => r.items!.toList());

      expect(result[0].value, equals(10));
      expect(result[0].label, equals('ten'));
      expect(result[1].value, equals(20));
      expect(result[1].label, equals('twenty'));
      expect(result[2].value, equals(30));
      expect(result[2].label, isNull);
    });

    test('empty struct list has length 0', () {
      expect(_rt((b) => b.initItems(0), (r) => r.items!.length), equals(0));
    });

    test('single-element struct list', () {
      expect(
        _rt((b) => b.initItems(1)..[0].value = 99, (r) => r.items![0].value),
        equals(99),
      );
    });

    test('struct list with 100 elements', () {
      final result = _rt((b) {
        final items = b.initItems(100);
        for (var i = 0; i < 100; i++) {
          items[i].value = i;
        }
      }, (r) => r.items!.map((e) => e.value).toList());
      expect(result, equals(List.generate(100, (i) => i)));
    });
  });

  group('RangeError on out-of-bounds access', () {
    test('Int32 list throws RangeError', () {
      final msg = MessageBuilder();
      final list = msg.initRoot(containerFactory).initInt32s(3);
      expect(() => list[3], throwsRangeError);
      expect(() => list[-1], throwsRangeError);
    });

    test('Bool list throws RangeError', () {
      final msg = MessageBuilder();
      final list = msg.initRoot(containerFactory).initBools(2);
      expect(() => list[2], throwsRangeError);
    });
  });

  group('Multiple list fields in one message', () {
    test('all fields coexist', () {
      final result = _rt((b) {
        final ints = b.initInt32s(2);
        ints[0] = 7;
        ints[1] = 14;
        b.initTexts(1)[0] = 'hi';
        b.initBools(1)[0] = true;
      }, (r) => (r.int32s!.toList(), r.texts![0], r.bools![0]));
      expect(result.$1, equals([7, 14]));
      expect(result.$2, equals('hi'));
      expect(result.$3, isTrue);
    });
  });

  group('NestedListBuilder (List(List(T)))', () {
    test('round-trip List(List(Float64)) with 2 rows of varying length', () {
      final result = _rtNested(
        (b) {
          final rows = b.initRows(2);
          final row0 = rows.initAt(0, 3);
          row0[0] = 1.0;
          row0[1] = 2.0;
          row0[2] = 3.0;
          final row1 = rows.initAt(1, 2);
          row1[0] = 4.0;
          row1[1] = 5.0;
        },
        (r) {
          final rows = r.rows!;
          return [rows[0]!.toList(), rows[1]!.toList()];
        },
      );
      expect(result[0], equals([1.0, 2.0, 3.0]));
      expect(result[1], equals([4.0, 5.0]));
    });

    test('empty outer list round-trips', () {
      final result = _rtNested((b) => b.initRows(0), (r) => r.rows!.length);
      expect(result, equals(0));
    });

    test('outer slot with empty inner list round-trips', () {
      final result = _rtNested((b) {
        final rows = b.initRows(1);
        rows.initAt(0, 0);
      }, (r) => r.rows![0]!.length);
      expect(result, equals(0));
    });

    test('initAt throws RangeError for out-of-bounds index', () {
      final msg = MessageBuilder();
      final rows = msg.initRoot(nestedContainerFactory).initRows(2);
      expect(() => rows.initAt(2, 1), throwsRangeError);
      expect(() => rows.initAt(-1, 1), throwsRangeError);
    });
  });

  group('NestedListBuilder (List(List(List(Int32))))', () {
    test('round-trip 2×2×3 tensor', () {
      final result = _rtNested(
        (b) {
          final mats = b.initMatrices(2);
          final mat0 = mats.initAt(0, 2);
          mat0.initAt(0, 3)
            ..[0] = 1
            ..[1] = 2
            ..[2] = 3;
          mat0.initAt(1, 3)
            ..[0] = 4
            ..[1] = 5
            ..[2] = 6;
          final mat1 = mats.initAt(1, 2);
          mat1.initAt(0, 3)
            ..[0] = 7
            ..[1] = 8
            ..[2] = 9;
          mat1.initAt(1, 3)
            ..[0] = 10
            ..[1] = 11
            ..[2] = 12;
        },
        (r) {
          final mats = r.matrices!;
          return [
            for (var i = 0; i < 2; i++)
              [for (var j = 0; j < 2; j++) mats[i]![j]!.toList()],
          ];
        },
      );
      expect(
        result,
        equals([
          [
            [1, 2, 3],
            [4, 5, 6],
          ],
          [
            [7, 8, 9],
            [10, 11, 12],
          ],
        ]),
      );
    });
  });

  // ─── Dynamic List API — element type validation (Fix 2) ─────────────────────

  group('DynamicListReader element type validation', () {
    DynamicListReader makeReader(ListElementSize elementSize, int count) {
      final mb = MessageBuilder();
      DynamicStructBuilder(mb.initRoot(_onePtrFactory).raw)
          .initDynamicListField(0, elementSize: elementSize, count: count);
      return MessageReader.deserialize(mb.serialize())
          .getRoot(_onePtrFactory)
          .getAnyPointerField(0)!
          .asDynamicList()!;
    }

    test('getInt64 on byte list throws DecodeException', () {
      final r = makeReader(ListElementSize.byte, 4);
      expect(r.getUint8(0), 0); // correct accessor works
      expect(() => r.getInt64(0), throwsA(isA<DecodeException>()));
    });

    test('getUint8 on pointer list throws DecodeException', () {
      final r = makeReader(ListElementSize.pointer, 2);
      expect(() => r.getUint8(0), throwsA(isA<DecodeException>()));
    });

    test('getText on fourBytes list throws DecodeException', () {
      final r = makeReader(ListElementSize.fourBytes, 2);
      expect(() => r.getText(0), throwsA(isA<DecodeException>()));
    });

    test('getCapabilityIndex on byte list throws DecodeException', () {
      final r = makeReader(ListElementSize.byte, 4);
      expect(() => r.getCapabilityIndex(0), throwsA(isA<DecodeException>()));
    });

    test('getBool on byte list throws DecodeException', () {
      final r = makeReader(ListElementSize.byte, 8);
      expect(() => r.getBool(0), throwsA(isA<DecodeException>()));
    });

    test('getFloat64 on eightBytes list succeeds', () {
      final mb = MessageBuilder();
      final listBuilder =
          DynamicStructBuilder(mb.initRoot(_onePtrFactory).raw)
              .initDynamicListField(
                0,
                elementSize: ListElementSize.eightBytes,
                count: 1,
              );
      listBuilder.setFloat64(0, 3.14);
      final r = MessageReader.deserialize(mb.serialize())
          .getRoot(_onePtrFactory)
          .getAnyPointerField(0)!
          .asDynamicList()!;
      expect(r.getFloat64(0), closeTo(3.14, 1e-10));
      expect(() => r.getInt32(0), throwsA(isA<DecodeException>()));
    });
  });

  group('DynamicListBuilder element type validation', () {
    DynamicListBuilder makeBuilder(ListElementSize elementSize, int count) {
      return DynamicStructBuilder(MessageBuilder().initRoot(_onePtrFactory).raw)
          .initDynamicListField(0, elementSize: elementSize, count: count);
    }

    test('setInt64 on byte list throws DecodeException', () {
      final b = makeBuilder(ListElementSize.byte, 4);
      expect(() => b.setInt64(0, 42), throwsA(isA<DecodeException>()));
    });

    test('setUint8 on composite list throws DecodeException', () {
      final b = makeBuilder(
        ListElementSize.composite,
        2,
      );
      expect(() => b.setUint8(0, 1), throwsA(isA<DecodeException>()));
    });

    test('setCapabilityIndex on byte list throws DecodeException', () {
      final b = makeBuilder(ListElementSize.byte, 4);
      expect(() => b.setCapabilityIndex(0, 0), throwsA(isA<DecodeException>()));
    });

    test('setBool on eightBytes list throws DecodeException', () {
      final b = makeBuilder(ListElementSize.eightBytes, 2);
      expect(() => b.setBool(0, true), throwsA(isA<DecodeException>()));
    });

    test('setText on pointer list succeeds (no type confusion)', () {
      final b = makeBuilder(ListElementSize.pointer, 2);
      expect(() => b.setText(0, 'hello'), returnsNormally);
    });
  });

  // ─── Capability pointer kind validation (Fix 3) ──────────────────────────────

  group('StructReader.getCapabilityField pointer kind validation', () {
    test('returns -1 for null pointer (unset field)', () {
      final mb = MessageBuilder();
      mb.initRoot(containerFactory);
      final reader =
          MessageReader.deserialize(mb.serialize()).getRoot(containerFactory);
      // ptrIndex 0 (bools) is null when unset
      expect(reader.getCapabilityField(0), -1);
    });

    test('throws DecodeException for non-capability pointer (text field)', () {
      final mb = MessageBuilder();
      mb.initRoot(containerFactory).initTexts(1)[0] = 'hello';
      final reader =
          MessageReader.deserialize(mb.serialize()).getRoot(containerFactory);
      // ptrIndex 4 (texts) has a ListPointer, not a CapabilityPointer
      expect(
        () => reader.getCapabilityField(4),
        throwsA(isA<DecodeException>()),
      );
    });
  });

  group('CapabilityListReader pointer kind validation', () {
    ({DynamicListReader listReader}) makePointerListWithNested() {
      final mb = MessageBuilder();
      final listBuilder =
          DynamicStructBuilder(mb.initRoot(_onePtrFactory).raw)
              .initDynamicListField(
                0,
                elementSize: ListElementSize.pointer,
                count: 2,
              );
      // Slot 0: put a nested byte list (ListPointer, not CapabilityPointer)
      listBuilder.initList(0, elementSize: ListElementSize.byte, count: 1);
      // Slot 1: leave as null (NullPointer)
      return (
        listReader: MessageReader.deserialize(mb.serialize())
            .getRoot(_onePtrFactory)
            .getAnyPointerField(0)!
            .asDynamicList()!,
      );
    }

    test('returns -1 for null slot', () {
      final (:listReader) = makePointerListWithNested();
      final capReader = CapabilityListReader(listReader.raw);
      expect(capReader[1], -1);
    });

    test('throws DecodeException for non-null non-capability pointer', () {
      final (:listReader) = makePointerListWithNested();
      final capReader = CapabilityListReader(listReader.raw);
      expect(() => capReader[0], throwsA(isA<DecodeException>()));
    });
  });

  group('TypedCapabilityListReader pointer kind validation', () {
    test('returns null for null slot', () {
      final mb = MessageBuilder();
      DynamicStructBuilder(mb.initRoot(_onePtrFactory).raw)
          .initDynamicListField(
            0,
            elementSize: ListElementSize.pointer,
            count: 2,
          );
      final listReader = MessageReader.deserialize(mb.serialize())
          .getRoot(_onePtrFactory)
          .getAnyPointerField(0)!
          .asDynamicList()!;
      final typedReader = TypedCapabilityListReader<String>(
        listReader.raw,
        const [],
        (cap) => cap as String,
      );
      expect(typedReader[0], isNull);
    });

    test('throws DecodeException for non-null non-capability pointer', () {
      final mb = MessageBuilder();
      final listBuilder =
          DynamicStructBuilder(mb.initRoot(_onePtrFactory).raw)
              .initDynamicListField(
                0,
                elementSize: ListElementSize.pointer,
                count: 1,
              );
      listBuilder.initList(0, elementSize: ListElementSize.byte, count: 1);
      final listReader = MessageReader.deserialize(mb.serialize())
          .getRoot(_onePtrFactory)
          .getAnyPointerField(0)!
          .asDynamicList()!;
      final typedReader = TypedCapabilityListReader<String>(
        listReader.raw,
        const [],
        (cap) => cap as String,
      );
      expect(() => typedReader[0], throwsA(isA<DecodeException>()));
    });
  });

  group('AnyPointerReader.capabilityIndex pointer kind validation', () {
    test('throws DecodeException for non-capability pointer in slot', () {
      final mb = MessageBuilder();
      // Put a list pointer in the AnyPointer slot
      DynamicStructBuilder(mb.initRoot(_onePtrFactory).raw)
          .initDynamicListField(
            0,
            elementSize: ListElementSize.byte,
            count: 1,
          );
      final reader = MessageReader.deserialize(mb.serialize())
          .getRoot(_onePtrFactory);
      final anyPtr = reader.getAnyPointerField(0)!;
      expect(() => anyPtr.capabilityIndex, throwsA(isA<DecodeException>()));
    });
  });
}
