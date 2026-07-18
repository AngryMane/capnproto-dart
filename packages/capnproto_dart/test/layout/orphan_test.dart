import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart' show RawStructReader;
import 'package:capnproto_dart/src/layout/list_builder.dart';
import 'package:capnproto_dart/src/layout/list_reader.dart';
import 'package:capnproto_dart/src/layout/orphan.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Hand-written structs simulating generated code, mirroring the style in
// struct_field_test.dart.
// ---------------------------------------------------------------------------

// struct Inner { value @0 :Int32; }
// Layout: dataWords = 1, ptrWords = 0
class InnerReader extends StructReader {
  InnerReader(super.raw);
  int get value => getInt32Field(0);
}

class InnerBuilder extends StructBuilder {
  InnerBuilder(super.raw);
  set value(int v) => setInt32Field(0, v);

  @override
  InnerReader asReader() => InnerReader(rawToReader());
}

class _InnerFactory extends StructFactory<InnerReader, InnerBuilder> {
  @override
  int get dataWords => 1;
  @override
  int get ptrWords => 0;
  @override
  InnerReader fromRawReader(RawStructReader raw) => InnerReader(raw);
  @override
  InnerBuilder fromRawBuilder(RawStructBuilder raw) => InnerBuilder(raw);
}

final innerFactory = _InnerFactory();

// struct Outer {
//   a @0 :Inner;
//   b @1 :Inner;
//   values @2 :List(Int32);
//   items @3 :List(Inner);
// }
// Layout: dataWords = 0, ptrWords = 4
const _outerAPtr = 0;
const _outerBPtr = 1;
const _outerValuesPtr = 2;
const _outerItemsPtr = 3;

class OuterReader extends StructReader {
  OuterReader(super.raw);
  InnerReader? get a => getStructFieldWith(_outerAPtr, (r) => InnerReader(r));
  InnerReader? get b => getStructFieldWith(_outerBPtr, (r) => InnerReader(r));
  ListReader<int>? get values => getInt32ListField(_outerValuesPtr);
  ListReader<InnerReader>? get items =>
      getStructListFieldWith(_outerItemsPtr, (r) => InnerReader(r));
}

class OuterBuilder extends StructBuilder {
  OuterBuilder(super.raw);
  InnerBuilder initA() =>
      initStructFieldWith(_outerAPtr, (r) => InnerBuilder(r), 1, 0);
  InnerBuilder initB() =>
      initStructFieldWith(_outerBPtr, (r) => InnerBuilder(r), 1, 0);
  ListBuilder<int> initValues(int count) =>
      initInt32ListField(_outerValuesPtr, count);
  ListBuilder<InnerBuilder> initItems(int count) =>
      initStructListFieldWith(_outerItemsPtr, count, (r) => InnerBuilder(r), 1, 0);

  @override
  OuterReader asReader() => OuterReader(rawToReader());
}

class _OuterFactory extends StructFactory<OuterReader, OuterBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 4;
  @override
  OuterReader fromRawReader(RawStructReader raw) => OuterReader(raw);
  @override
  OuterBuilder fromRawBuilder(RawStructBuilder raw) => OuterBuilder(raw);
}

final outerFactory = _OuterFactory();

void main() {
  group('StructBuilder.disownPointerField / adoptPointerField — struct', () {
    test('moving a struct field to another field preserves content and '
        'clears the source', () {
      final msg = MessageBuilder();
      final outer = msg.initRoot(outerFactory);
      outer.initA().value = 42;

      final orphan = outer.disownPointerField(_outerAPtr);
      expect(orphan, isA<StructOrphan>());
      expect(outer.asReader().a, isNull);

      outer.adoptPointerField(_outerBPtr, orphan);
      expect(outer.asReader().b?.value, equals(42));
    });

    test('disowning an unset field returns null', () {
      final msg = MessageBuilder();
      final outer = msg.initRoot(outerFactory);
      expect(outer.disownPointerField(_outerAPtr), isNull);
    });

    test('adopting null clears the destination field', () {
      final msg = MessageBuilder();
      final outer = msg.initRoot(outerFactory);
      outer.initB().value = 1;
      expect(outer.asReader().b, isNotNull);

      outer.adoptPointerField(_outerBPtr, null);
      expect(outer.asReader().b, isNull);
    });
  });

  group('StructBuilder.disownPointerField / adoptPointerField — list', () {
    test('moving a primitive list field preserves its elements', () {
      final msg = MessageBuilder();
      final outer = msg.initRoot(outerFactory);
      final values = outer.initValues(3);
      values[0] = 10;
      values[1] = 20;
      values[2] = 30;

      final orphan = outer.disownPointerField(_outerValuesPtr);
      expect(orphan, isA<ListOrphan>());
      expect(outer.asReader().values, isNull);

      outer.adoptPointerField(_outerBPtr, orphan);
      // b's static type is Inner, not List(Int32) — read back through the
      // generic (inherited) list getter at that slot instead, to confirm
      // the bytes moved correctly regardless of static field typing.
      final list = outer.asReader().getInt32ListField(_outerBPtr);
      expect(list, isNotNull);
      expect(list!.toList(), equals([10, 20, 30]));
    });

    test('moving a composite (struct) list field preserves every element', () {
      final msg = MessageBuilder();
      final outer = msg.initRoot(outerFactory);
      final items = outer.initItems(2);
      items[0].value = 100;
      items[1].value = 200;

      final orphan = outer.disownPointerField(_outerItemsPtr);
      expect(outer.asReader().items, isNull);

      outer.adoptPointerField(_outerValuesPtr, orphan);
      final list = outer.asReader().getStructListFieldWith(
        _outerValuesPtr,
        (r) => InnerReader(r),
      );
      expect(list, isNotNull);
      expect(list!.map((e) => e.value).toList(), equals([100, 200]));
    });
  });

  group('Orphan safety checks', () {
    test('adopting into a different MessageBuilder throws ArgumentError', () {
      final msgA = MessageBuilder();
      final outerA = msgA.initRoot(outerFactory);
      outerA.initA().value = 1;
      final orphan = outerA.disownPointerField(_outerAPtr);

      final msgB = MessageBuilder();
      final outerB = msgB.initRoot(outerFactory);
      expect(
        () => outerB.adoptPointerField(_outerAPtr, orphan),
        throwsArgumentError,
      );
    });

    test('adopting the same Orphan twice throws StateError', () {
      final msg = MessageBuilder();
      final outer = msg.initRoot(outerFactory);
      outer.initA().value = 1;
      final orphan = outer.disownPointerField(_outerAPtr);

      outer.adoptPointerField(_outerBPtr, orphan);
      expect(
        () => outer.adoptPointerField(_outerAPtr, orphan),
        throwsStateError,
      );
    });

    test('disowning a capability pointer throws UnsupportedError', () {
      final msg = MessageBuilder();
      final outer = msg.initRoot(outerFactory);
      outer.setCapabilityField(_outerAPtr, 0);
      expect(
        () => outer.disownPointerField(_outerAPtr),
        throwsUnsupportedError,
      );
    });
  });

  group('Cross-segment adopt', () {
    test('adopting content from a different segment resolves correctly '
        '(double-far pointer)', () {
      final arena = ArenaBuilder();
      final (rootSeg, rootPtrOff) = arena.allocate(1);
      final outerRaw = arena.allocateStruct(
        ptrSeg: rootSeg,
        ptrWordOffset: rootPtrOff,
        dataWords: 0,
        ptrWords: 4,
      );
      final outer = OuterBuilder(outerRaw);

      // Force a brand-new segment to become the arena's current bump
      // segment, so that building "a" next lands in a different segment
      // than "outer" itself (segment 0).
      arena.allocate(2000);

      outer.initA().value = 99;
      expect(outerRaw.segment.id, equals(0));

      final orphan = outer.disownPointerField(_outerAPtr) as StructOrphan;
      expect(orphan.raw.segment.id, isNot(equals(0)));

      outer.adoptPointerField(_outerBPtr, orphan);
      expect(outer.asReader().b?.value, equals(99));
    });
  });

  group('MessageBuilder.adoptRoot', () {
    test('re-roots the message onto a struct disowned from elsewhere in '
        'the same message', () {
      final msg = MessageBuilder();
      final outer = msg.initRoot(outerFactory);
      outer.initA().value = 7;
      final orphan = outer.disownPointerField(_outerAPtr) as StructOrphan;

      // Re-root the SAME message (adoptRoot is same-arena-only — see
      // orphan.dart) onto the disowned Inner, replacing the Outer that was
      // there.
      final inner = msg.adoptRoot(orphan, innerFactory);
      expect(inner.asReader().value, equals(7));

      // Confirm the arena is still coherent by serializing it.
      expect(msg.serialize(), isNotEmpty);
    });
  });
}
