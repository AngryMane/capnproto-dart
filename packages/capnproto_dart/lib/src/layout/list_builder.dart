import 'dart:typed_data';

import '../arena/arena_builder.dart';
import '../wire/wire_helpers.dart';

/// Writable view of a Cap'n Proto list field.
///
/// Generated code uses one of the typed helpers on [StructBuilder] rather than
/// constructing these directly.
abstract class ListBuilder<T> {
  int get length;

  T operator [](int index);

  void operator []=(int index, T value);
}

// ---- Concrete implementations ----

/// Builder for bit-packed [bool] lists.
class BoolListBuilder extends ListBuilder<bool> {
  final RawListBuilder _raw;

  BoolListBuilder(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  bool operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    final byteIndex = index ~/ 8;
    final bitMask = 1 << (index & 7);
    return (readUint8(_raw.segment.data, _raw.dataByteOffset + byteIndex) &
            bitMask) !=
        0;
  }

  @override
  void operator []=(int index, bool value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    final byteIndex = index ~/ 8;
    final bitMask = 1 << (index & 7);
    final absOffset = _raw.dataByteOffset + byteIndex;
    final current = readUint8(_raw.segment.data, absOffset);
    writeUint8(
      _raw.segment.data,
      absOffset,
      value ? (current | bitMask) : (current & ~bitMask),
    );
  }
}

/// Builder for fixed-size integer lists (all signed and unsigned integer types).
class PrimitiveIntListBuilder extends ListBuilder<int> {
  final RawListBuilder _raw;
  final int Function(ByteData, int) _read;
  final void Function(ByteData, int, int) _write;
  final int _elementBytes;

  PrimitiveIntListBuilder(
      this._raw, this._read, this._write, this._elementBytes);

  @override
  int get length => _raw.elementCount;

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    return _read(_raw.segment.data, _raw.dataByteOffset + index * _elementBytes);
  }

  @override
  void operator []=(int index, int value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    _write(
        _raw.segment.data, _raw.dataByteOffset + index * _elementBytes, value);
  }
}

/// Builder for fixed-size floating-point lists (Float32 and Float64).
class PrimitiveDoubleListBuilder extends ListBuilder<double> {
  final RawListBuilder _raw;
  final double Function(ByteData, int) _read;
  final void Function(ByteData, int, double) _write;
  final int _elementBytes;

  PrimitiveDoubleListBuilder(
      this._raw, this._read, this._write, this._elementBytes);

  @override
  int get length => _raw.elementCount;

  @override
  double operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    return _read(_raw.segment.data, _raw.dataByteOffset + index * _elementBytes);
  }

  @override
  void operator []=(int index, double value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    _write(
        _raw.segment.data, _raw.dataByteOffset + index * _elementBytes, value);
  }
}

/// Builder for Text (UTF-8 String) pointer lists.
///
/// Reading elements (`[]`) is not supported on a builder; use
/// `serialize` + `MessageReader` to read back written text.
class TextListBuilder extends ListBuilder<String?> {
  final RawListBuilder _raw;

  TextListBuilder(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  String? operator [](int index) {
    throw UnsupportedError(
        'reading from TextListBuilder is not supported; serialize and deserialize to read back');
  }

  @override
  void operator []=(int index, String? value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    _raw.arena.writeTextField(_raw.segment, ptrWordOffset, value);
  }
}

/// Builder for Data (raw bytes) pointer lists.
class DataListBuilder extends ListBuilder<Uint8List?> {
  final RawListBuilder _raw;

  DataListBuilder(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  Uint8List? operator [](int index) {
    throw UnsupportedError(
        'reading from DataListBuilder is not supported; serialize and deserialize to read back');
  }

  @override
  void operator []=(int index, Uint8List? value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    _raw.arena.writeDataField(_raw.segment, ptrWordOffset, value);
  }
}

/// Builder for `List(Void)` fields.
///
/// Void list elements carry no data; only the length is meaningful.
class VoidListBuilder extends ListBuilder<Null> {
  final RawListBuilder _raw;

  VoidListBuilder(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  Null operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    return null;
  }

  @override
  void operator []=(int index, Null value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    // Void elements have no data.
  }
}

/// Builder for lists of enum values stored as 16-bit unsigned integers.
///
/// The `[]` operator throws; serialize and deserialize to read back written
/// values (consistent with [TextListBuilder] and [DataListBuilder]).
class EnumListBuilder<E> extends ListBuilder<E> {
  final RawListBuilder _raw;
  final int Function(E) _toInt;

  EnumListBuilder(this._raw, this._toInt);

  @override
  int get length => _raw.elementCount;

  @override
  E operator [](int index) =>
      throw UnsupportedError(
          'reading from EnumListBuilder is not supported; '
          'serialize and deserialize to read back');

  @override
  void operator []=(int index, E value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    writeUint16(_raw.segment.data, _raw.dataByteOffset + index * 2, _toInt(value));
  }
}

/// Builder for composite struct lists.
///
/// Call `builder[i]` to get the mutable builder for element `i` and modify
/// it in place. The `[]=` operator is not meaningful for struct elements.
class StructListBuilder<B> extends ListBuilder<B> {
  final RawListBuilder _raw;
  final B Function(RawStructBuilder) _fromRaw;

  StructListBuilder(this._raw, this._fromRaw);

  @override
  int get length => _raw.elementCount;

  @override
  B operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    final stride =
        (_raw.structDataWords + _raw.structPtrWords) * bytesPerWord;
    final elementWordOffset =
        (_raw.dataByteOffset + index * stride) ~/ bytesPerWord;
    return _fromRaw(RawStructBuilder(
      segment: _raw.segment,
      arena: _raw.arena,
      dataWordOffset: elementWordOffset,
      dataWords: _raw.structDataWords,
      ptrWordOffset: elementWordOffset + _raw.structDataWords,
      ptrWords: _raw.structPtrWords,
    ));
  }

  @override
  void operator []=(int index, B value) {
    throw UnsupportedError(
        'use builder[i] to get a struct element builder and modify it in place');
  }
}
