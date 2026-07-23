import 'dart:typed_data';

import '../arena/arena_reader.dart';
import '../exception/decode_exception.dart';
import '../wire/pointer.dart'
    show CapabilityPointer, ListElementSize, NullPointer, WirePointer;
import '../wire/wire_helpers.dart';

/// Read-only, iterable view of a Cap'n Proto list field.
///
/// Subclasses (or the concrete implementations below) provide typed element
/// access. Generated code uses one of the typed helpers on [StructReader]
/// rather than constructing these directly.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
abstract class ListReader<T> extends Iterable<T> {
  @override
  int get length;

  /// Performs this operation.
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
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.moveNext;
  /// ```
  bool moveNext() {
    _index++;
    return _index < _list.length;
  }
}

// ---- Concrete implementations ----

/// List of bit-packed [bool] values.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class BoolListReader extends ListReader<bool> {
  final RawListReader _raw;

  /// Creates a [BoolListReader] instance.
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class PrimitiveIntListReader extends ListReader<int> {
  final RawListReader _raw;
  final int Function(ByteData, int) _read;
  final int _elementBytes;

  /// Creates a [PrimitiveIntListReader] instance.
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class PrimitiveDoubleListReader extends ListReader<double> {
  final RawListReader _raw;
  final double Function(ByteData, int) _read;
  final int _elementBytes;

  /// Creates a [PrimitiveDoubleListReader] instance.
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class TextListReader extends ListReader<String?> {
  final RawListReader _raw;

  /// Creates a [TextListReader] instance.
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class DataListReader extends ListReader<Uint8List?> {
  final RawListReader _raw;

  /// Creates a [DataListReader] instance.
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
///
/// A `List(Struct)` field's wire representation is usually `composite`, but
/// Cap'n Proto's schema-evolution rules also allow reading a struct list
/// back from a list that a peer or older schema version wrote as a plain
/// non-struct list before the field's type became a struct (see
/// https://capnproto.org/language.html, "upgrading a list to a struct
/// list"). That's only representable here when the original element already
/// occupies exactly one whole word — `pointer` (the struct becomes `{ f0
/// :SomeInterface/AnyPointer/... }`) and `eightBytes` (the struct becomes
/// `{ f0 :Int64/UInt64/Float64 }`) — because [RawStructReader]'s addressing
/// is word-granular: `void` upgrades trivially too, since every "element" is
/// legitimately the same empty struct. Sub-word element sizes (`bit`,
/// `byte`, `twoBytes`, `fourBytes`) would need a byte-granular struct
/// addressing model this codebase doesn't have — reading those as a struct
/// list throws [DecodeException] instead of silently aliasing every
/// "element" onto the same offset (stride 0, since [RawListReader]'s
/// `structDataWords`/`structPtrWords` default to 0 for non-composite lists).
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class StructListReader<R> extends ListReader<R> {
  final RawListReader _raw;
  final R Function(RawStructReader) _fromRaw;
  final int _elementDataWords;
  final int _elementPtrWords;

  /// Creates a [StructListReader] instance.
  StructListReader(this._raw, this._fromRaw)
    : _elementDataWords = switch (_raw.elementSize) {
        ListElementSize.eightBytes => 1,
        _ => _raw.structDataWords,
      },
      _elementPtrWords = switch (_raw.elementSize) {
        ListElementSize.pointer => 1,
        _ => _raw.structPtrWords,
      } {
    switch (_raw.elementSize) {
      case ListElementSize.composite:
      case ListElementSize.pointer:
      case ListElementSize.eightBytes:
      case ListElementSize.void_:
        break;
      default:
        throw DecodeException(
          'cannot read a List(${_raw.elementSize.name}) as List(Struct): '
          'only composite, pointer, eightBytes, and void element sizes can '
          'be upgraded to a struct list',
        );
    }
  }

  @override
  int get length => _raw.elementCount;

  @override
  R operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final stride = (_elementDataWords + _elementPtrWords) * bytesPerWord;
    final elementWordOffset =
        (_raw.dataByteOffset + index * stride) ~/ bytesPerWord;
    return _fromRaw(
      RawStructReader(
        segment: _raw.segment,
        arena: _raw.arena,
        dataWordOffset: elementWordOffset,
        dataWords: _elementDataWords,
        ptrWordOffset: elementWordOffset + _elementDataWords,
        ptrWords: _elementPtrWords,
        nestingLimit: _raw.nestingLimit,
      ),
    );
  }
}

/// List of Void elements (Cap'n Proto `List(Void)`).
///
/// Void lists store only a count; every element access returns null.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class VoidListReader extends ListReader<Null> {
  final RawListReader _raw;

  /// Creates a [VoidListReader] instance.
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class EnumListReader<E> extends ListReader<E?> {
  final RawListReader _raw;
  final E? Function(int) _fromInt;

  /// Creates a [EnumListReader] instance.
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class NestedListReader<T> extends ListReader<ListReader<T>?> {
  final RawListReader _raw;
  final ListReader<T>? Function(RawListReader) _fromRaw;

  /// Creates a [NestedListReader] instance.
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

/// Performs the [voidListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = voidListFromRaw(raw);
/// ```
ListReader<Null> voidListFromRaw(RawListReader raw) => VoidListReader(raw);

/// Performs the [boolListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = boolListFromRaw(raw);
/// ```
ListReader<bool> boolListFromRaw(RawListReader raw) => BoolListReader(raw);

/// Performs the [int8ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = int8ListFromRaw(raw);
/// ```
ListReader<int> int8ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readInt8, 1);

/// Performs the [int16ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = int16ListFromRaw(raw);
/// ```
ListReader<int> int16ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readInt16, 2);

/// Performs the [int32ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = int32ListFromRaw(raw);
/// ```
ListReader<int> int32ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readInt32, 4);

/// Performs the [int64ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = int64ListFromRaw(raw);
/// ```
ListReader<int> int64ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readInt64, 8);

/// Performs the [uint8ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = uint8ListFromRaw(raw);
/// ```
ListReader<int> uint8ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readUint8, 1);

/// Performs the [uint16ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = uint16ListFromRaw(raw);
/// ```
ListReader<int> uint16ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readUint16, 2);

/// Performs the [uint32ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = uint32ListFromRaw(raw);
/// ```
ListReader<int> uint32ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readUint32, 4);

/// Performs the [uint64ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = uint64ListFromRaw(raw);
/// ```
ListReader<int> uint64ListFromRaw(RawListReader raw) =>
    PrimitiveIntListReader(raw, readUint64, 8);

/// Performs the [float32ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = float32ListFromRaw(raw);
/// ```
ListReader<double> float32ListFromRaw(RawListReader raw) =>
    PrimitiveDoubleListReader(raw, readFloat32, 4);

/// Performs the [float64ListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = float64ListFromRaw(raw);
/// ```
ListReader<double> float64ListFromRaw(RawListReader raw) =>
    PrimitiveDoubleListReader(raw, readFloat64, 8);

/// Performs the [textListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = textListFromRaw(raw);
/// ```
ListReader<String?> textListFromRaw(RawListReader raw) => TextListReader(raw);

/// Performs the [dataListFromRaw] operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = dataListFromRaw(raw);
/// ```
ListReader<Uint8List?> dataListFromRaw(RawListReader raw) =>
    DataListReader(raw);

/// Performs this operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = enumListFromRaw(raw, fromOrdinal);
/// ```
ListReader<E?> enumListFromRaw<E>(
  RawListReader raw,
  E? Function(int) fromInt,
) => EnumListReader<E>(raw, fromInt);

/// Performs this operation.
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = structListFromRaw(raw, factory);
/// ```
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class CapabilityListReader extends ListReader<int> {
  final RawListReader _raw;

  /// Creates a [CapabilityListReader] instance.
  CapabilityListReader(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    final ptr = WirePointer.decode(_raw.segment.data, ptrWordOffset);
    if (ptr is NullPointer) return -1;
    if (ptr is CapabilityPointer) return ptr.capabilityIndex;
    throw DecodeException(
      'expected capability pointer, got ${ptr.runtimeType}',
    );
  }
}

/// Typed view over a `List(Interface)` using an RPC capability table.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class TypedCapabilityListReader<T> extends ListReader<T?> {
  final RawListReader _raw;
  final List<Object?> _capabilities;
  final T Function(Object capability) _fromCapability;

  /// Creates a [TypedCapabilityListReader] instance.
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
    if (ptr is NullPointer) return null;
    if (ptr is! CapabilityPointer) {
      throw DecodeException(
        'expected capability pointer, got ${ptr.runtimeType}',
      );
    }
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
///
/// **Intended users**
/// * Generated `capnpc_dart` bindings and custom code generators.
///
/// **Primary use cases**
/// * Adapts an untyped wire-layout view to the typed list API expected by generated bindings.
///
/// **Parameters**
/// * Function parameters supply the source value and any schema, options, or conversion callbacks required by the operation.
///
/// **Returns**
/// * A typed reader or builder view over the supplied raw list.
///
/// **Example**
/// ```dart
/// // Given the required message, schema, or raw-layout values:
/// final values = capabilityListFromRaw(raw);
/// ```
ListReader<int> capabilityListFromRaw(RawListReader raw) =>
    CapabilityListReader(raw);
