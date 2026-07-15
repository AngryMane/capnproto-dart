import 'dart:typed_data';

const int bytesPerWord = 8;

int readUint8(ByteData data, int byteOffset) => data.getUint8(byteOffset);
int readUint16(ByteData data, int byteOffset) =>
    data.getUint16(byteOffset, Endian.little);
int readUint32(ByteData data, int byteOffset) =>
    data.getUint32(byteOffset, Endian.little);
int readUint64(ByteData data, int byteOffset) =>
    data.getUint64(byteOffset, Endian.little);

int readInt8(ByteData data, int byteOffset) => data.getInt8(byteOffset);
int readInt16(ByteData data, int byteOffset) =>
    data.getInt16(byteOffset, Endian.little);
int readInt32(ByteData data, int byteOffset) =>
    data.getInt32(byteOffset, Endian.little);
int readInt64(ByteData data, int byteOffset) =>
    data.getInt64(byteOffset, Endian.little);

double readFloat32(ByteData data, int byteOffset) =>
    data.getFloat32(byteOffset, Endian.little);
double readFloat64(ByteData data, int byteOffset) =>
    data.getFloat64(byteOffset, Endian.little);

void writeUint8(ByteData data, int byteOffset, int value) =>
    data.setUint8(byteOffset, value);
void writeUint16(ByteData data, int byteOffset, int value) =>
    data.setUint16(byteOffset, value, Endian.little);
void writeUint32(ByteData data, int byteOffset, int value) =>
    data.setUint32(byteOffset, value, Endian.little);
void writeUint64(ByteData data, int byteOffset, int value) =>
    data.setUint64(byteOffset, value, Endian.little);

void writeInt8(ByteData data, int byteOffset, int value) =>
    data.setInt8(byteOffset, value);
void writeInt16(ByteData data, int byteOffset, int value) =>
    data.setInt16(byteOffset, value, Endian.little);
void writeInt32(ByteData data, int byteOffset, int value) =>
    data.setInt32(byteOffset, value, Endian.little);
void writeInt64(ByteData data, int byteOffset, int value) =>
    data.setInt64(byteOffset, value, Endian.little);

void writeFloat32(ByteData data, int byteOffset, double value) =>
    data.setFloat32(byteOffset, value, Endian.little);
void writeFloat64(ByteData data, int byteOffset, double value) =>
    data.setFloat64(byteOffset, value, Endian.little);

/// Reinterprets an unsigned 32-bit value (0..2^32-1) as a signed 32-bit value.
/// Required when decoding signed 30-bit offsets from pointer words.
int reinterpretAsInt32(int uint32) =>
    uint32 >= 0x80000000 ? uint32 - 0x100000000 : uint32;

int reinterpretFloat32AsUint32(double value) {
  final bd = ByteData(4)..setFloat32(0, value, Endian.little);
  return bd.getUint32(0, Endian.little);
}

double reinterpretUint32AsFloat32(int bits) {
  final bd = ByteData(4)..setUint32(0, bits, Endian.little);
  return bd.getFloat32(0, Endian.little);
}

int reinterpretFloat64AsUint64(double value) {
  final bd = ByteData(8)..setFloat64(0, value, Endian.little);
  return bd.getUint64(0, Endian.little);
}

double reinterpretUint64AsFloat64(int bits) {
  final bd = ByteData(8)..setUint64(0, bits, Endian.little);
  return bd.getFloat64(0, Endian.little);
}
