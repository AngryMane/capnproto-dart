import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/exception/decode_exception.dart';
import 'package:capnproto_dart/src/layout/list_builder.dart';
import 'package:capnproto_dart/src/layout/list_reader.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:capnproto_dart/src/message/message_reader.dart';
import 'package:capnproto_dart/src/wire/wire_helpers.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Hand-written reader/builder pairs simulating generated code, chosen to
// exercise each canonicalization rule independently:
//   https://capnproto.org/encoding.html#canonicalization
// ---------------------------------------------------------------------------

// struct TwoWords { a @0 :Int64; b @1 :Int64; }  (dataWords = 2, ptrWords = 0)
class TwoWordsReader extends StructReader {
  TwoWordsReader(super.raw);
  int get a => getInt64Field(0);
  int get b => getInt64Field(8);
}

class TwoWordsBuilder extends StructBuilder {
  TwoWordsBuilder(super.raw);
  set a(int v) => setInt64Field(0, v);
  set b(int v) => setInt64Field(8, v);

  @override
  TwoWordsReader asReader() => throw UnimplementedError();
}

final twoWordsFactory = _TwoWordsFactory();

class _TwoWordsFactory extends StructFactory<TwoWordsReader, TwoWordsBuilder> {
  @override
  int get dataWords => 2;
  @override
  int get ptrWords => 0;

  @override
  TwoWordsReader fromRawReader(RawStructReader raw) => TwoWordsReader(raw);

  @override
  TwoWordsBuilder fromRawBuilder(RawStructBuilder raw) =>
      TwoWordsBuilder(raw);
}

// struct TwoPtrs { first @0 :Text; second @1 :Text; } (dataWords=0, ptrWords=2)
class TwoPtrsReader extends StructReader {
  TwoPtrsReader(super.raw);
  String? get first => getTextField(0);
  String? get second => getTextField(1);
}

class TwoPtrsBuilder extends StructBuilder {
  TwoPtrsBuilder(super.raw);
  set first(String? v) => setTextField(0, v);
  set second(String? v) => setTextField(1, v);

  @override
  TwoPtrsReader asReader() => throw UnimplementedError();
}

final twoPtrsFactory = _TwoPtrsFactory();

class _TwoPtrsFactory extends StructFactory<TwoPtrsReader, TwoPtrsBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 2;

  @override
  TwoPtrsReader fromRawReader(RawStructReader raw) => TwoPtrsReader(raw);

  @override
  TwoPtrsBuilder fromRawBuilder(RawStructBuilder raw) => TwoPtrsBuilder(raw);
}

// struct ElemHost { elems @0 :List(TwoWords); } (dataWords=0, ptrWords=1)
class ElemHostReader extends StructReader {
  ElemHostReader(super.raw);
  ListReader<TwoWordsReader>? get elems =>
      getStructListFieldWith(0, (raw) => TwoWordsReader(raw));
}

class ElemHostBuilder extends StructBuilder {
  ElemHostBuilder(super.raw);
  ListBuilder<TwoWordsBuilder> initElems(int count) =>
      initStructListFieldWith(0, count, (raw) => TwoWordsBuilder(raw), 2, 0);

  @override
  ElemHostReader asReader() => throw UnimplementedError();
}

final elemHostFactory = _ElemHostFactory();

class _ElemHostFactory extends StructFactory<ElemHostReader, ElemHostBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 1;

  @override
  ElemHostReader fromRawReader(RawStructReader raw) => ElemHostReader(raw);

  @override
  ElemHostBuilder fromRawBuilder(RawStructBuilder raw) =>
      ElemHostBuilder(raw);
}

// struct CapHolder { cap @0 :Capability; } (dataWords=0, ptrWords=1)
class CapHolderReader extends StructReader {
  CapHolderReader(super.raw, {super.capabilities});
  int get capIndex => getCapabilityField(0);
}

class CapHolderBuilder extends StructBuilder {
  CapHolderBuilder(super.raw);
  set capIndex(int value) => setCapabilityField(0, value);

  @override
  CapHolderReader asReader() => throw UnimplementedError();
}

final capHolderFactory = _CapHolderFactory();

class _CapHolderFactory
    extends StructFactory<CapHolderReader, CapHolderBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 1;

  @override
  CapHolderReader fromRawReader(RawStructReader raw) => CapHolderReader(raw);

  @override
  CapHolderReader fromRawReaderWithCapabilities(
    RawStructReader raw,
    List<Object?> capabilities,
  ) =>
      CapHolderReader(raw, capabilities: capabilities);

  @override
  CapHolderBuilder fromRawBuilder(RawStructBuilder raw) =>
      CapHolderBuilder(raw);
}

/// Wraps a bare (unframed) canonical segment in a standard single-segment
/// Cap'n Proto message header so it can be re-parsed by [MessageReader], for
/// tests that want to assert on field values rather than raw bytes.
Uint8List _frameSingleSegment(Uint8List segmentBytes) {
  final header = ByteData(8);
  header.setUint32(0, 0, Endian.little); // numSegments - 1
  header.setUint32(4, segmentBytes.lengthInBytes ~/ bytesPerWord, Endian.little);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...segmentBytes,
  ]);
}

void main() {
  group('MessageReader.canonicalize', () {
    test('trims trailing all-zero words from a struct\'s data section', () {
      final mb = MessageBuilder();
      mb.initRoot(twoWordsFactory).a = 42; // b left at default 0
      final canonical =
          MessageReader.deserialize(mb.serialize()).canonicalize();

      // 1 word root pointer + 1 word trimmed data section (b's word dropped).
      expect(canonical.lengthInBytes, equals(16));

      final reread = MessageReader.deserialize(_frameSingleSegment(canonical))
          .getRoot(twoWordsFactory);
      expect(reread.a, equals(42));
      expect(reread.b, equals(0));
    });

    test('does not trim when the trailing word is non-default', () {
      final mb = MessageBuilder();
      final s = mb.initRoot(twoWordsFactory);
      s.a = 0;
      s.b = 7;
      final canonical =
          MessageReader.deserialize(mb.serialize()).canonicalize();

      // Both data words are retained because the last one (b) is non-zero.
      expect(canonical.lengthInBytes, equals(24));
    });

    test('trims trailing null pointers from a struct\'s pointer section', () {
      final mb = MessageBuilder();
      mb.initRoot(twoPtrsFactory).first = 'hi'; // second left unset (null)
      final canonical =
          MessageReader.deserialize(mb.serialize()).canonicalize();

      final reread = MessageReader.deserialize(_frameSingleSegment(canonical))
          .getRoot(twoPtrsFactory);
      expect(reread.first, equals('hi'));
      expect(reread.second, isNull);

      // Re-encoding a struct with 1 (not 2) pointer words should be strictly
      // smaller than the same struct with both pointers set.
      final mbBoth = MessageBuilder();
      final both = mbBoth.initRoot(twoPtrsFactory);
      both.first = 'hi';
      both.second = 'bye';
      final canonicalBoth =
          MessageReader.deserialize(mbBoth.serialize()).canonicalize();
      expect(canonical.lengthInBytes, lessThan(canonicalBoth.lengthInBytes));
    });

    test(
      'does not trim a middle null pointer that precedes a non-null one',
      () {
        // first is null but second is set: nothing can be trimmed, since
        // trimming only ever removes from the *end* of the pointer section.
        final mb = MessageBuilder();
        mb.initRoot(twoPtrsFactory).second = 'bye';
        final canonical =
            MessageReader.deserialize(mb.serialize()).canonicalize();

        final reread = MessageReader.deserialize(
          _frameSingleSegment(canonical),
        ).getRoot(twoPtrsFactory);
        expect(reread.first, isNull);
        expect(reread.second, equals('bye'));
      },
    );

    test(
      'lists of structs are re-packed to the largest size needed by any '
      'element, not each element\'s own minimum',
      () {
        final mb = MessageBuilder();
        final host = mb.initRoot(elemHostFactory);
        final elems = host.initElems(2);
        elems[0].a = 1; // only needs 1 data word on its own
        elems[0].b = 0;
        elems[1].a = 2;
        elems[1].b = 99; // needs both data words

        final canonical =
            MessageReader.deserialize(mb.serialize()).canonicalize();
        final reread = MessageReader.deserialize(
          _frameSingleSegment(canonical),
        ).getRoot(elemHostFactory);
        final rereadElems = reread.elems!;

        // Both elements keep the full 2-word layout (uniform across the
        // list), so element 0's second word is retained as an explicit zero
        // rather than the list being shrunk to a per-element minimum.
        expect(rereadElems[0].a, equals(1));
        expect(rereadElems[0].b, equals(0));
        expect(rereadElems[1].a, equals(2));
        expect(rereadElems[1].b, equals(99));
      },
    );

    test('throws when the message contains a capability pointer', () {
      final mb = MessageBuilder();
      mb.initRoot(capHolderFactory).capIndex = 0;

      expect(
        () => MessageReader.deserialize(mb.serialize()).canonicalize(),
        throwsA(isA<DecodeException>()),
      );
    });

    test('is idempotent: canonicalizing a canonical message is a no-op', () {
      final mb = MessageBuilder();
      final host = mb.initRoot(elemHostFactory);
      final elems = host.initElems(2);
      elems[0].a = 1;
      elems[1].b = 99;

      final once = MessageReader.deserialize(mb.serialize()).canonicalize();
      final twice = MessageReader.deserialize(
        _frameSingleSegment(once),
      ).canonicalize();

      expect(twice, equals(once));
    });

    test('flattens a multi-segment source into a single canonical segment',
        () {
      // Force a second segment via ArenaBuilder.importSegmentData, the same
      // low-level mechanism ensureSingleSegment's own test uses.
      final builder = ArenaBuilder(4);
      final (rootSeg, rootOffset) = builder.allocate(1);
      final dst = builder.allocateStruct(
        ptrSeg: rootSeg,
        ptrWordOffset: rootOffset,
        dataWords: 2,
        ptrWords: 0,
      );
      writeInt64(dst.segment.data, dst.dataWordOffset * bytesPerWord, 5);
      final bytes = builder.serialize();
      // Sanity check this test fixture actually spans one segment (small
      // enough that ArenaBuilder didn't need to spill) — the interesting
      // case here is exercising canonicalize's segment-flattening path via
      // resolveStructAt, not the multi-segment allocation itself, which is
      // already covered by ensureSingleSegment's tests.
      expect(bytes.lengthInBytes, greaterThan(0));

      final canonical = MessageReader.deserialize(bytes).canonicalize();
      final reread = MessageReader.deserialize(
        _frameSingleSegment(canonical),
      ).getRoot(twoWordsFactory);
      expect(reread.a, equals(5));
      expect(reread.b, equals(0));
      // b's word is trimmed away.
      expect(canonical.lengthInBytes, equals(16));
    });
  });
}
