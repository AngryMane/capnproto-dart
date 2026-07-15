import 'dart:typed_data';

import 'package:capnproto_dart/src/wire/pointer.dart';
import 'package:test/test.dart';

ByteData _buf() => ByteData(8);

void main() {
  group('NullPointer', () {
    test('all-zero bytes decode to NullPointer', () {
      expect(WirePointer.decode(_buf(), 0), isA<NullPointer>());
    });

    test('encode produces all-zero bytes', () {
      final data = _buf();
      const NullPointer().encode(data, 0);
      for (var i = 0; i < 8; i++) {
        expect(data.getUint8(i), equals(0), reason: 'byte $i should be 0');
      }
    });
  });

  group('StructPointer', () {
    test('encode/decode roundtrip: positive offset', () {
      final data = _buf();
      const StructPointer(offset: 5, dataWords: 3, ptrWords: 2).encode(data, 0);
      final p = WirePointer.decode(data, 0) as StructPointer;
      expect(p.offset, equals(5));
      expect(p.dataWords, equals(3));
      expect(p.ptrWords, equals(2));
    });

    test('encode/decode roundtrip: negative offset', () {
      final data = _buf();
      const StructPointer(offset: -1, dataWords: 1, ptrWords: 0).encode(data, 0);
      final p = WirePointer.decode(data, 0) as StructPointer;
      expect(p.offset, equals(-1));
    });

    test('encode/decode roundtrip: max field values', () {
      final data = _buf();
      const StructPointer(
        offset: (1 << 29) - 1, // max positive 30-bit signed
        dataWords: 0xFFFF,
        ptrWords: 0xFFFF,
      ).encode(data, 0);
      final p = WirePointer.decode(data, 0) as StructPointer;
      expect(p.offset, equals((1 << 29) - 1));
      expect(p.dataWords, equals(0xFFFF));
      expect(p.ptrWords, equals(0xFFFF));
    });

    test('type bits are 00', () {
      final data = _buf();
      const StructPointer(offset: 1, dataWords: 0, ptrWords: 0).encode(data, 0);
      expect(data.getUint8(0) & 3, equals(0));
    });
  });

  group('ListPointer', () {
    test('encode/decode roundtrip: eightBytes elements', () {
      final data = _buf();
      const ListPointer(
        offset: 3,
        elementSize: ListElementSize.eightBytes,
        elementCountOrWordCount: 100,
      ).encode(data, 0);
      final p = WirePointer.decode(data, 0) as ListPointer;
      expect(p.offset, equals(3));
      expect(p.elementSize, equals(ListElementSize.eightBytes));
      expect(p.elementCountOrWordCount, equals(100));
    });

    test('encode/decode roundtrip: composite elements', () {
      final data = _buf();
      const ListPointer(
        offset: 0,
        elementSize: ListElementSize.composite,
        elementCountOrWordCount: 64,
      ).encode(data, 0);
      final p = WirePointer.decode(data, 0) as ListPointer;
      expect(p.elementSize, equals(ListElementSize.composite));
      expect(p.elementCountOrWordCount, equals(64));
    });

    test('encode/decode roundtrip: negative offset', () {
      final data = _buf();
      const ListPointer(
        offset: -5,
        elementSize: ListElementSize.byte,
        elementCountOrWordCount: 10,
      ).encode(data, 0);
      final p = WirePointer.decode(data, 0) as ListPointer;
      expect(p.offset, equals(-5));
    });

    test('type bits are 01', () {
      final data = _buf();
      const ListPointer(
        offset: 1,
        elementSize: ListElementSize.byte,
        elementCountOrWordCount: 1,
      ).encode(data, 0);
      expect(data.getUint8(0) & 3, equals(1));
    });

    test('all element size values roundtrip', () {
      for (final size in ListElementSize.values) {
        final data = _buf();
        ListPointer(
          offset: 1,
          elementSize: size,
          elementCountOrWordCount: 1,
        ).encode(data, 0);
        final p = WirePointer.decode(data, 0) as ListPointer;
        expect(p.elementSize, equals(size), reason: 'size=${size.name}');
      }
    });
  });

  group('FarPointer', () {
    test('encode/decode roundtrip: single-far', () {
      final data = _buf();
      const FarPointer(
        isDoubleFar: false,
        landingPadOffset: 10,
        segmentId: 2,
      ).encode(data, 0);
      final p = WirePointer.decode(data, 0) as FarPointer;
      expect(p.isDoubleFar, isFalse);
      expect(p.landingPadOffset, equals(10));
      expect(p.segmentId, equals(2));
    });

    test('encode/decode roundtrip: double-far', () {
      final data = _buf();
      const FarPointer(
        isDoubleFar: true,
        landingPadOffset: 0,
        segmentId: 5,
      ).encode(data, 0);
      final p = WirePointer.decode(data, 0) as FarPointer;
      expect(p.isDoubleFar, isTrue);
      expect(p.segmentId, equals(5));
    });

    test('type bits are 10', () {
      final data = _buf();
      const FarPointer(isDoubleFar: false, landingPadOffset: 0, segmentId: 0)
          .encode(data, 0);
      expect(data.getUint8(0) & 3, equals(2));
    });
  });

  group('CapabilityPointer', () {
    test('encode/decode roundtrip', () {
      final data = _buf();
      const CapabilityPointer(capabilityIndex: 42).encode(data, 0);
      final p = WirePointer.decode(data, 0) as CapabilityPointer;
      expect(p.capabilityIndex, equals(42));
    });

    test('max index', () {
      final data = _buf();
      const CapabilityPointer(capabilityIndex: 0xFFFFFFFF).encode(data, 0);
      final p = WirePointer.decode(data, 0) as CapabilityPointer;
      expect(p.capabilityIndex, equals(0xFFFFFFFF));
    });

    test('type bits are 11', () {
      final data = _buf();
      const CapabilityPointer(capabilityIndex: 0).encode(data, 0);
      // lo should be 3 (bits 00000011)
      expect(data.getUint8(0) & 3, equals(3));
    });
  });

  group('word offset', () {
    test('decode from second word position', () {
      final data = ByteData(16);
      const StructPointer(offset: 7, dataWords: 1, ptrWords: 0).encode(data, 1);
      expect(WirePointer.decode(data, 0), isA<NullPointer>());
      final p = WirePointer.decode(data, 1) as StructPointer;
      expect(p.offset, equals(7));
    });
  });
}
