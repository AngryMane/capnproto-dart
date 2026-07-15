import 'dart:typed_data';

import '../arena/arena_reader.dart';
import '../wire/wire_helpers.dart';

/// Read-only, iterable view of a Cap'n Proto list field.
///
/// Subclasses (or the concrete implementations below) provide typed element
/// access. Generated code uses one of the typed helpers on [StructReader]
/// rather than constructing these directly.
abstract class ListReader<T> extends Iterable<T> {
  @override
  int get length;

  T operator [](int index);

  @override
  Iterator<T> get iterator => _ListReaderIterator(this);
}

class _ListReaderIterator<T> implements Iterator<T> {
  final ListReader<T> _list;
  int _index = -1;

  _ListReaderIterator(this._list);

  @override
  T get current => _list[_index];

  @override
  bool moveNext() {
    _index++;
    return _index < _list.length;
  }
}

// ---- Concrete implementations ----

/// List of bit-packed [bool] values.
class BoolListReader extends ListReader<bool> {
  final RawListReader _raw;

  BoolListReader(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  bool operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final byteIndex = index ~/ 8;
    final bitMask = 1 << (index & 7);
    return (readUint8(_raw.segment.data, _raw.dataByteOffset + byteIndex) &
            bitMask) !=
        0;
  }
}

/// List of fixed-size integer values (all signed and unsigned integer types).
class PrimitiveIntListReader extends ListReader<int> {
  final RawListReader _raw;
  final int Function(ByteData, int) _read;
  final int _elementBytes;

  PrimitiveIntListReader(this._raw, this._read, this._elementBytes);

  @override
  int get length => _raw.elementCount;

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _read(_raw.segment.data, _raw.dataByteOffset + index * _elementBytes);
  }
}

/// List of fixed-size floating-point values (Float32 and Float64).
class PrimitiveDoubleListReader extends ListReader<double> {
  final RawListReader _raw;
  final double Function(ByteData, int) _read;
  final int _elementBytes;

  PrimitiveDoubleListReader(this._raw, this._read, this._elementBytes);

  @override
  int get length => _raw.elementCount;

  @override
  double operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _read(_raw.segment.data, _raw.dataByteOffset + index * _elementBytes);
  }
}

/// List of Text (UTF-8 String) fields stored as pointers.
class TextListReader extends ListReader<String?> {
  final RawListReader _raw;

  TextListReader(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  String? operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    return _raw.arena.resolveTextAt(_raw.segment, ptrWordOffset);
  }
}

/// List of Data (raw bytes) fields stored as pointers.
class DataListReader extends ListReader<Uint8List?> {
  final RawListReader _raw;

  DataListReader(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  Uint8List? operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    return _raw.arena.resolveDataAt(_raw.segment, ptrWordOffset);
  }
}

/// List of composite struct elements.
///
/// [R] is the typed reader for each element. Uses a callback [fromRaw] to
/// avoid an import cycle between the layout and struct layers.
class StructListReader<R> extends ListReader<R> {
  final RawListReader _raw;
  final R Function(RawStructReader) _fromRaw;

  StructListReader(this._raw, this._fromRaw);

  @override
  int get length => _raw.elementCount;

  @override
  R operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final stride =
        (_raw.structDataWords + _raw.structPtrWords) * bytesPerWord;
    final elementWordOffset =
        (_raw.dataByteOffset + index * stride) ~/ bytesPerWord;
    return _fromRaw(RawStructReader(
      segment: _raw.segment,
      arena: _raw.arena,
      dataWordOffset: elementWordOffset,
      dataWords: _raw.structDataWords,
      ptrWordOffset: elementWordOffset + _raw.structDataWords,
      ptrWords: _raw.structPtrWords,
      nestingLimit: _raw.nestingLimit,
    ));
  }
}
