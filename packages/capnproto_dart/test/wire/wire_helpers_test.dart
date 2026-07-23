import 'dart:typed_data';

import 'package:capnproto_dart/src/wire/wire_helpers.dart';
import 'package:test/test.dart';

void main() {
  group('readUint32 / writeUint32', () {
    test('roundtrip: zero', () {
      final data = ByteData(4);
      writeUint32(data, 0, 0);
      expect(readUint32(data, 0), equals(0));
    });

    test('roundtrip: max value', () {
      final data = ByteData(4);
      writeUint32(data, 0, 0xFFFFFFFF);
      expect(readUint32(data, 0), equals(0xFFFFFFFF));
    });

    test('little-endian byte order', () {
      final data = ByteData(4);
      writeUint32(data, 0, 0x01020304);
      expect(data.getUint8(0), equals(0x04));
      expect(data.getUint8(1), equals(0x03));
      expect(data.getUint8(2), equals(0x02));
      expect(data.getUint8(3), equals(0x01));
    });
  });

  group('readInt32', () {
    test('positive value', () {
      final data = ByteData(4);
      writeUint32(data, 0, 42);
      expect(readInt32(data, 0), equals(42));
    });

    test('negative: all ones', () {
      final data = ByteData(4);
      writeUint32(data, 0, 0xFFFFFFFF);
      expect(readInt32(data, 0), equals(-1));
    });

    test('negative: min int32', () {
      final data = ByteData(4);
      writeUint32(data, 0, 0x80000000);
      expect(readInt32(data, 0), equals(-2147483648));
    });
  });

  group('reinterpretAsInt32', () {
    test('zero stays zero', () => expect(reinterpretAsInt32(0), equals(0)));
    test('max positive', () =>
        expect(reinterpretAsInt32(0x7FFFFFFF), equals(2147483647)));
    test('min negative (0x80000000)', () =>
        expect(reinterpretAsInt32(0x80000000), equals(-2147483648)));
    test('all-ones = -1', () =>
        expect(reinterpretAsInt32(0xFFFFFFFF), equals(-1)));
  });

  group('float roundtrips', () {
    test('float32', () {
      final data = ByteData(4);
      writeFloat32(data, 0, 1.5);
      expect(readFloat32(data, 0), closeTo(1.5, 1e-6));
    });

    test('float64', () {
      final data = ByteData(8);
      writeFloat64(data, 0, 3.141592653589793);
      expect(readFloat64(data, 0), closeTo(3.141592653589793, 1e-15));
    });
  });

  group('int64 roundtrip', () {
    test('large positive value', () {
      final data = ByteData(8);
      const value = 0x0102030405060708;
      writeInt64(data, 0, value);
      expect(readInt64(data, 0), equals(value));
    });

    test('negative value', () {
      final data = ByteData(8);
      writeInt64(data, 0, -1);
      expect(readInt64(data, 0), equals(-1));
    });
  });
}
