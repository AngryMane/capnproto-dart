import 'dart:typed_data';

import '../arena/arena_reader.dart';
import '../exception/decode_exception.dart';
import '../wire/pointer.dart' show CapabilityPointer, WirePointer;
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
    return _read(
      _raw.segment.data,
      _raw.dataByteOffset + index * _elementBytes,
    );
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
    return _read(
      _raw.segment.data,
      _raw.dataByteOffset + index * _elementBytes,
    );
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
    final stride = (_raw.structDataWords + _raw.structPtrWords) * bytesPerWord;
    final elementWordOffset =
        (_raw.dataByteOffset + index * stride) ~/ bytesPerWord;
    return _fromRaw(
      RawStructReader(
        segment: _raw.segment,
        arena: _raw.arena,
        dataWordOffset: elementWordOffset,
        dataWords: _raw.structDataWords,
        ptrWordOffset: elementWordOffset + _raw.structDataWords,
        ptrWords: _raw.structPtrWords,
        nestingLimit: _raw.nestingLimit,
      ),
    );
  }
}

/// List of Void elements (Cap'n Proto `List(Void)`).
///
/// Void lists store only a count; every element access returns null.
class VoidListReader extends ListReader<Null> {
  final RawListReader _raw;

  VoidListReader(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  Null operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return null;
  }
}

/// List of enum elements stored as 16-bit unsigned integers.
///
/// [E] is the Dart enum type. [_fromInt] maps raw uint16 values to [E?],
/// returning null for unknown discriminants from newer schemas.
class EnumListReader<E> extends ListReader<E?> {
  final RawListReader _raw;
  final E? Function(int) _fromInt;

  EnumListReader(this._raw, this._fromInt);

  @override
  int get length => _raw.elementCount;

  @override
  E? operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final v = readUint16(_raw.segment.data, _raw.dataByteOffset + index * 2);
    return _fromInt(v);
  }
}

/// List whose elements are themselves lists — used for Cap'n Proto
/// `List(List(T))` fields.
///
/// Each element slot holds a pointer; [_fromRaw] converts the resolved
/// [RawListReader] into the typed inner [ListReader<T>].
class NestedListReader<T> extends ListReader<ListReader<T>?> {
  final RawListReader _raw;
  final ListReader<T>? Function(RawListReader) _fromRaw;

  NestedListReader(this._raw, this._fromRaw);

  @override
  int get length => _raw.elementCount;

  @override
  ListReader<T>? operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    final inner = _raw.arena.resolveListAt(
      _raw.segment,
      ptrWordOffset,
      _raw.nestingLimit,
    );
    return inner == null ? null : _fromRaw(inner);
  }
}

// ---------------------------------------------------------------------------
// Raw-to-typed factory functions — for use in nested-list lambdas in
// generated code (e.g. `getNestedListField(0, float64ListFromRaw)`).
// ---------------------------------------------------------------------------

ListReader<Null> voidListFromRaw(RawListReader raw) => VoidListReader(raw);
ListReader<bool> boolListFromRaw(RawListReader raw) => BoolListReader(raw);
ListReader<int> int8ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readInt8, 1);
ListReader<int> int16ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readInt16, 2);
ListReader<int> int32ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readInt32, 4);
ListReader<int> int64ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readInt64, 8);
ListReader<int> uint8ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readUint8, 1);
ListReader<int> uint16ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readUint16, 2);
ListReader<int> uint32ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readUint32, 4);
ListReader<int> uint64ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readUint64, 8);
ListReader<double> float32ListFromRaw(RawListReader raw) =>
    PrimitiveDoubleListReader(raw, readFloat32, 4);
ListReader<double> float64ListFromRaw(RawListReader raw) =>
    PrimitiveDoubleListReader(raw, readFloat64, 8);
ListReader<String?> textListFromRaw(RawListReader raw) => TextListReader(raw);
ListReader<Uint8List?> dataListFromRaw(RawListReader raw) =>
    DataListReader(raw);
ListReader<E?> enumListFromRaw<E>(
  RawListReader raw,
  E? Function(int) fromInt,
) => EnumListReader<E>(raw, fromInt);
ListReader<R> structListFromRaw<R>(
  RawListReader raw,
  R Function(RawStructReader) fromRaw,
) => StructListReader<R>(raw, fromRaw);

/// List of capability references stored as cap-table indices.
///
/// In Cap'n Proto, `List(Interface)` encodes each element as a
/// [CapabilityPointer] word. This reader decodes the high-32-bit
/// capabilityIndex from each word and returns it as an [int].
/// Generated code wraps these indices using the companion cap-table list
/// (e.g. `paramsCapabilities[index]`) to obtain actual [Capability] objects.
class CapabilityListReader extends ListReader<int> {
  final RawListReader _raw;

  CapabilityListReader(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    final ptr = WirePointer.decode(_raw.segment.data, ptrWordOffset);
    return ptr is CapabilityPointer ? ptr.capabilityIndex : -1;
  }
}

/// Typed view over a `List(Interface)` using an RPC capability table.
class TypedCapabilityListReader<T> extends ListReader<T?> {
  final RawListReader _raw;
  final List<Object?> _capabilities;
  final T Function(Object capability) _fromCapability;

  TypedCapabilityListReader(
    this._raw,
    this._capabilities,
    this._fromCapability,
  );

  @override
  int get length => _raw.elementCount;

  @override
  T? operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    final ptr = WirePointer.decode(_raw.segment.data, ptrWordOffset);
    if (ptr is! CapabilityPointer) return null;
    final capIndex = ptr.capabilityIndex;
    if (capIndex >= _capabilities.length) {
      throw DecodeException(
        'capability table index $capIndex is out of range for ${_capabilities.length} capabilities',
      );
    }
    final cap = _capabilities[capIndex];
    if (cap == null) {
      throw DecodeException('capability table index $capIndex is null');
    }
    return _fromCapability(cap);
  }
}

/// Creates a [CapabilityListReader] from a [RawListReader].
ListReader<int> capabilityListFromRaw(RawListReader raw) =>
    CapabilityListReader(raw);
