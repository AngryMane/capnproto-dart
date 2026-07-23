import 'dart:typed_data';

import '../arena/arena_builder.dart';
import '../wire/pointer.dart' show CapabilityPointer, WirePointer;
import '../wire/wire_helpers.dart';

/// Writable view of a Cap'n Proto list field.
///
/// Generated code uses one of the typed helpers on [StructBuilder] rather than
/// constructing these directly.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
abstract class ListBuilder<T> {
  /// Returns the current [length] value.
  int get length;

  /// Performs this operation.
  T operator [](int index);

  /// Performs this operation.
  void operator []=(int index, T value);
}

// ---- Concrete implementations ----

/// Builder for bit-packed [bool] lists.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class BoolListBuilder extends ListBuilder<bool> {
  final RawListBuilder _raw;

  /// Creates a [BoolListBuilder] instance.
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class PrimitiveIntListBuilder extends ListBuilder<int> {
  final RawListBuilder _raw;
  final int Function(ByteData, int) _read;
  final void Function(ByteData, int, int) _write;
  final int _elementBytes;

  /// Creates a [PrimitiveIntListBuilder] instance.
  PrimitiveIntListBuilder(
    this._raw,
    this._read,
    this._write,
    this._elementBytes,
  );

  @override
  int get length => _raw.elementCount;

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    return _read(
      _raw.segment.data,
      _raw.dataByteOffset + index * _elementBytes,
    );
  }

  @override
  void operator []=(int index, int value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    _write(
      _raw.segment.data,
      _raw.dataByteOffset + index * _elementBytes,
      value,
    );
  }
}

/// Builder for fixed-size floating-point lists (Float32 and Float64).
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class PrimitiveDoubleListBuilder extends ListBuilder<double> {
  final RawListBuilder _raw;
  final double Function(ByteData, int) _read;
  final void Function(ByteData, int, double) _write;
  final int _elementBytes;

  /// Creates a [PrimitiveDoubleListBuilder] instance.
  PrimitiveDoubleListBuilder(
    this._raw,
    this._read,
    this._write,
    this._elementBytes,
  );

  @override
  int get length => _raw.elementCount;

  @override
  double operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    return _read(
      _raw.segment.data,
      _raw.dataByteOffset + index * _elementBytes,
    );
  }

  @override
  void operator []=(int index, double value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    _write(
      _raw.segment.data,
      _raw.dataByteOffset + index * _elementBytes,
      value,
    );
  }
}

/// Builder for Text (UTF-8 String) pointer lists.
///
/// Reading elements (`[]`) is not supported on a builder; use
/// `serialize` + `MessageReader` to read back written text.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class TextListBuilder extends ListBuilder<String?> {
  final RawListBuilder _raw;

  /// Creates a [TextListBuilder] instance.
  TextListBuilder(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  String? operator [](int index) {
    throw UnsupportedError(
      'reading from TextListBuilder is not supported; serialize and deserialize to read back',
    );
  }

  @override
  void operator []=(int index, String? value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    _raw.arena.writeTextField(_raw.segment, ptrWordOffset, value);
  }
}

/// Builder for Data (raw bytes) pointer lists.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class DataListBuilder extends ListBuilder<Uint8List?> {
  final RawListBuilder _raw;

  /// Creates a [DataListBuilder] instance.
  DataListBuilder(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  Uint8List? operator [](int index) {
    throw UnsupportedError(
      'reading from DataListBuilder is not supported; serialize and deserialize to read back',
    );
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class VoidListBuilder extends ListBuilder<Null> {
  final RawListBuilder _raw;

  /// Creates a [VoidListBuilder] instance.
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
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class EnumListBuilder<E> extends ListBuilder<E> {
  final RawListBuilder _raw;
  final int Function(E) _toInt;

  /// Creates a [EnumListBuilder] instance.
  EnumListBuilder(this._raw, this._toInt);

  @override
  int get length => _raw.elementCount;

  @override
  E operator [](int index) =>
      throw UnsupportedError(
        'reading from EnumListBuilder is not supported; '
        'serialize and deserialize to read back',
      );

  @override
  void operator []=(int index, E value) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    writeUint16(
      _raw.segment.data,
      _raw.dataByteOffset + index * 2,
      _toInt(value),
    );
  }
}

/// Builder for composite struct lists.
///
/// Call `builder[i]` to get the mutable builder for element `i` and modify
/// it in place. The `[]=` operator is not meaningful for struct elements.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class StructListBuilder<B> extends ListBuilder<B> {
  final RawListBuilder _raw;
  final B Function(RawStructBuilder) _fromRaw;

  /// Creates a [StructListBuilder] instance.
  StructListBuilder(this._raw, this._fromRaw);

  @override
  int get length => _raw.elementCount;

  @override
  B operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    final stride = (_raw.structDataWords + _raw.structPtrWords) * bytesPerWord;
    final elementWordOffset =
        (_raw.dataByteOffset + index * stride) ~/ bytesPerWord;
    return _fromRaw(
      RawStructBuilder(
        segment: _raw.segment,
        arena: _raw.arena,
        dataWordOffset: elementWordOffset,
        dataWords: _raw.structDataWords,
        ptrWordOffset: elementWordOffset + _raw.structDataWords,
        ptrWords: _raw.structPtrWords,
      ),
    );
  }

  @override
  void operator []=(int index, B value) {
    throw UnsupportedError(
      'use builder[i] to get a struct element builder and modify it in place',
    );
  }
}

// ---------------------------------------------------------------------------
// NestedListBuilder — builder for List(List(T)) and List(List(List(T)))
// ---------------------------------------------------------------------------
/// Builder for nested list fields (`List(List(T))`).
///
/// Returned by [StructBuilder.initNestedListField]. Call [initAt] to allocate
/// the inner list at each outer slot.
///
/// For three-level nesting (`List(List(List(T)))`), [initAt] returns another
/// [NestedListBuilder]; see [StructBuilder.initBiNestedListField].
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class NestedListBuilder<T> {
  /// Holds the public [length] value.
  final int length;
  final T Function(int index, int innerCount) _initAt;

  /// Creates a [NestedListBuilder] instance.
  NestedListBuilder({
    required this.length,
    required T Function(int, int) initAt,
  }) : _initAt = initAt;

  /// Allocates [innerCount]-element inner list at outer slot [index] and
  /// returns a builder for it.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final child = builder.initAt(0);
  /// ```
  T initAt(int index, int innerCount) {
    RangeError.checkValidIndex(index, this, 'index', length);
    return _initAt(index, innerCount);
  }
}

// ---------------------------------------------------------------------------
// Builder factory functions — mirror of the reader-side xxxListFromRaw set.
// Used by generated code and StructBuilder.initNestedListField.
// ---------------------------------------------------------------------------

/// Creates a [VoidListBuilder] from a [RawListBuilder].
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
/// final values = voidListBuilderFromRaw(raw);
/// ```
ListBuilder<Null> voidListBuilderFromRaw(RawListBuilder raw) =>
    VoidListBuilder(raw);

/// Creates a [BoolListBuilder] from a [RawListBuilder].
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
/// final values = boolListBuilderFromRaw(raw);
/// ```
ListBuilder<bool> boolListBuilderFromRaw(RawListBuilder raw) =>
    BoolListBuilder(raw);

/// Creates an `Int8` [PrimitiveIntListBuilder] from a [RawListBuilder].
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
/// final values = int8ListBuilderFromRaw(raw);
/// ```
ListBuilder<int> int8ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveIntListBuilder(raw, readInt8, writeInt8, 1);

/// Creates an `Int16` [PrimitiveIntListBuilder] from a [RawListBuilder].
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
/// final values = int16ListBuilderFromRaw(raw);
/// ```
ListBuilder<int> int16ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveIntListBuilder(raw, readInt16, writeInt16, 2);

/// Creates an `Int32` [PrimitiveIntListBuilder] from a [RawListBuilder].
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
/// final values = int32ListBuilderFromRaw(raw);
/// ```
ListBuilder<int> int32ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveIntListBuilder(raw, readInt32, writeInt32, 4);

/// Creates an `Int64` [PrimitiveIntListBuilder] from a [RawListBuilder].
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
/// final values = int64ListBuilderFromRaw(raw);
/// ```
ListBuilder<int> int64ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveIntListBuilder(raw, readInt64, writeInt64, 8);

/// Creates a `UInt8` [PrimitiveIntListBuilder] from a [RawListBuilder].
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
/// final values = uint8ListBuilderFromRaw(raw);
/// ```
ListBuilder<int> uint8ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveIntListBuilder(raw, readUint8, writeUint8, 1);

/// Creates a `UInt16` [PrimitiveIntListBuilder] from a [RawListBuilder].
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
/// final values = uint16ListBuilderFromRaw(raw);
/// ```
ListBuilder<int> uint16ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveIntListBuilder(raw, readUint16, writeUint16, 2);

/// Creates a `UInt32` [PrimitiveIntListBuilder] from a [RawListBuilder].
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
/// final values = uint32ListBuilderFromRaw(raw);
/// ```
ListBuilder<int> uint32ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveIntListBuilder(raw, readUint32, writeUint32, 4);

/// Creates a `UInt64` [PrimitiveIntListBuilder] from a [RawListBuilder].
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
/// final values = uint64ListBuilderFromRaw(raw);
/// ```
ListBuilder<int> uint64ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveIntListBuilder(raw, readUint64, writeUint64, 8);

/// Creates a `Float32` [PrimitiveDoubleListBuilder] from a [RawListBuilder].
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
/// final values = float32ListBuilderFromRaw(raw);
/// ```
ListBuilder<double> float32ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveDoubleListBuilder(raw, readFloat32, writeFloat32, 4);

/// Creates a `Float64` [PrimitiveDoubleListBuilder] from a [RawListBuilder].
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
/// final values = float64ListBuilderFromRaw(raw);
/// ```
ListBuilder<double> float64ListBuilderFromRaw(RawListBuilder raw) =>
    PrimitiveDoubleListBuilder(raw, readFloat64, writeFloat64, 8);

/// Creates a [TextListBuilder] from a [RawListBuilder].
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
/// final values = textListBuilderFromRaw(raw);
/// ```
ListBuilder<String?> textListBuilderFromRaw(RawListBuilder raw) =>
    TextListBuilder(raw);

/// Creates a [DataListBuilder] from a [RawListBuilder].
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
/// final values = dataListBuilderFromRaw(raw);
/// ```
ListBuilder<Uint8List?> dataListBuilderFromRaw(RawListBuilder raw) =>
    DataListBuilder(raw);

/// Creates an [EnumListBuilder] from a [RawListBuilder] and a `toInt` function.
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
/// final values = enumListBuilderFromRaw(raw, fromOrdinal);
/// ```
ListBuilder<E> enumListBuilderFromRaw<E>(
  RawListBuilder raw,
  int Function(E) toInt,
) => EnumListBuilder<E>(raw, toInt);

/// Creates a [StructListBuilder] from a [RawListBuilder] and a `fromRaw`
/// factory function.
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
/// final values = structListBuilderFromRaw(raw, factory);
/// ```
ListBuilder<B> structListBuilderFromRaw<B>(
  RawListBuilder raw,
  B Function(RawStructBuilder) fromRaw,
) => StructListBuilder<B>(raw, fromRaw);

/// List builder for capability fields stored as cap-table indices.
///
/// Each element is an 8-byte pointer slot encoded as a [CapabilityPointer].
/// The integer value stored/read at each position is the cap table index.
/// Generated code uses [StructBuilder.initCapabilityListField] rather than
/// constructing this directly.
///
/// **Intended users**
/// * Authors of generated `capnpc_dart` bindings and low-level runtime integrations.
///
/// **Primary use cases**
/// * Supports the typed bindings that map schema declarations to the Cap'n Proto wire layout.
class CapabilityListBuilder extends ListBuilder<int> {
  final RawListBuilder _raw;

  /// Creates a [CapabilityListBuilder] instance.
  CapabilityListBuilder(this._raw);

  @override
  int get length => _raw.elementCount;

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    final ptrWordOffset = _raw.dataByteOffset ~/ bytesPerWord + index;
    final ptr = WirePointer.decode(_raw.segment.data, ptrWordOffset);
    return ptr is CapabilityPointer ? ptr.capabilityIndex : -1;
  }

  @override
  void operator []=(int index, int capTableIndex) {
    RangeError.checkValidIndex(index, this, 'index', _raw.elementCount);
    final byteOffset = _raw.dataByteOffset + index * bytesPerWord;
    CapabilityPointer(
      capabilityIndex: capTableIndex,
    ).encode(_raw.segment.data, byteOffset ~/ bytesPerWord);
  }
}

/// Creates a [CapabilityListBuilder] from a [RawListBuilder].
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
/// final values = capabilityListBuilderFromRaw(raw);
/// ```
ListBuilder<int> capabilityListBuilderFromRaw(RawListBuilder raw) =>
    CapabilityListBuilder(raw);
