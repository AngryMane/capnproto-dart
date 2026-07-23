import 'dart:typed_data';

/// Holds the public [bytesPerWord] value.
const int bytesPerWord = 8;

/// Performs the [readUint8] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readUint8;
/// ```
int readUint8(ByteData data, int byteOffset) => data.getUint8(byteOffset);

/// Performs the [readUint16] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readUint16;
/// ```
int readUint16(ByteData data, int byteOffset) =>
    data.getUint16(byteOffset, Endian.little);

/// Performs the [readUint32] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readUint32;
/// ```
int readUint32(ByteData data, int byteOffset) =>
    data.getUint32(byteOffset, Endian.little);

/// Performs the [readUint64] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readUint64;
/// ```
int readUint64(ByteData data, int byteOffset) =>
    data.getUint64(byteOffset, Endian.little);

/// Performs the [readInt8] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readInt8;
/// ```
int readInt8(ByteData data, int byteOffset) => data.getInt8(byteOffset);

/// Performs the [readInt16] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readInt16;
/// ```
int readInt16(ByteData data, int byteOffset) =>
    data.getInt16(byteOffset, Endian.little);

/// Performs the [readInt32] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readInt32;
/// ```
int readInt32(ByteData data, int byteOffset) =>
    data.getInt32(byteOffset, Endian.little);

/// Performs the [readInt64] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readInt64;
/// ```
int readInt64(ByteData data, int byteOffset) =>
    data.getInt64(byteOffset, Endian.little);

/// Performs the [readFloat32] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readFloat32;
/// ```
double readFloat32(ByteData data, int byteOffset) =>
    data.getFloat32(byteOffset, Endian.little);

/// Performs the [readFloat64] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = readFloat64;
/// ```
double readFloat64(ByteData data, int byteOffset) =>
    data.getFloat64(byteOffset, Endian.little);

/// Performs the [writeUint8] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeUint8;
/// ```
void writeUint8(ByteData data, int byteOffset, int value) =>
    data.setUint8(byteOffset, value);

/// Performs the [writeUint16] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeUint16;
/// ```
void writeUint16(ByteData data, int byteOffset, int value) =>
    data.setUint16(byteOffset, value, Endian.little);

/// Performs the [writeUint32] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeUint32;
/// ```
void writeUint32(ByteData data, int byteOffset, int value) =>
    data.setUint32(byteOffset, value, Endian.little);

/// Performs the [writeUint64] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeUint64;
/// ```
void writeUint64(ByteData data, int byteOffset, int value) =>
    data.setUint64(byteOffset, value, Endian.little);

/// Performs the [writeInt8] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeInt8;
/// ```
void writeInt8(ByteData data, int byteOffset, int value) =>
    data.setInt8(byteOffset, value);

/// Performs the [writeInt16] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeInt16;
/// ```
void writeInt16(ByteData data, int byteOffset, int value) =>
    data.setInt16(byteOffset, value, Endian.little);

/// Performs the [writeInt32] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeInt32;
/// ```
void writeInt32(ByteData data, int byteOffset, int value) =>
    data.setInt32(byteOffset, value, Endian.little);

/// Performs the [writeInt64] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeInt64;
/// ```
void writeInt64(ByteData data, int byteOffset, int value) =>
    data.setInt64(byteOffset, value, Endian.little);

/// Performs the [writeFloat32] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeFloat32;
/// ```
void writeFloat32(ByteData data, int byteOffset, double value) =>
    data.setFloat32(byteOffset, value, Endian.little);

/// Performs the [writeFloat64] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = writeFloat64;
/// ```
void writeFloat64(ByteData data, int byteOffset, double value) =>
    data.setFloat64(byteOffset, value, Endian.little);

/// Reinterprets an unsigned 32-bit value (0..2^32-1) as a signed 32-bit value.
/// Required when decoding signed 30-bit offsets from pointer words.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = reinterpretAsInt32;
/// ```
int reinterpretAsInt32(int uint32) =>
    uint32 >= 0x80000000 ? uint32 - 0x100000000 : uint32;

/// Performs the [reinterpretFloat32AsUint32] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = reinterpretFloat32AsUint32;
/// ```
int reinterpretFloat32AsUint32(double value) {
  final bd = ByteData(4)..setFloat32(0, value, Endian.little);
  return bd.getUint32(0, Endian.little);
}

/// Performs the [reinterpretUint32AsFloat32] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = reinterpretUint32AsFloat32;
/// ```
double reinterpretUint32AsFloat32(int bits) {
  final bd = ByteData(4)..setUint32(0, bits, Endian.little);
  return bd.getFloat32(0, Endian.little);
}

/// Performs the [reinterpretFloat64AsUint64] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = reinterpretFloat64AsUint64;
/// ```
int reinterpretFloat64AsUint64(double value) {
  final bd = ByteData(8)..setFloat64(0, value, Endian.little);
  return bd.getUint64(0, Endian.little);
}

/// Performs the [reinterpretUint64AsFloat64] operation.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final operation = reinterpretUint64AsFloat64;
/// ```
double reinterpretUint64AsFloat64(int bits) {
  final bd = ByteData(8)..setUint64(0, bits, Endian.little);
  return bd.getFloat64(0, Endian.little);
}
