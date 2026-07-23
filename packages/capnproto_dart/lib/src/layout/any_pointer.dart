import 'dart:typed_data';

import '../arena/arena_builder.dart';
import '../arena/arena_reader.dart';
import '../exception/decode_exception.dart';
import '../message/message_copy.dart';
import '../message/message_reader_options.dart';
import '../wire/pointer.dart';
import '../wire/wire_helpers.dart';
import 'list_builder.dart';
import 'list_reader.dart';
import 'struct_builder.dart';
import 'struct_factory.dart';
import 'struct_reader.dart';

/// Encodes and decodes values carried through schema type parameters.
///
/// Cap'n Proto represents a type parameter at runtime as an `AnyPointer`.
/// Generated generic-method helpers accept an [AnyPointerCodec] so callers can
/// decide how each type argument is serialized while the generated code keeps
/// capability tables and pointer copying rules consistent.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
abstract interface class AnyPointerCodec<T> {
  /// Performs the [encode] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// codec.encode(builder, value);
  /// ```
  void encode(
    AnyPointerBuilder builder,
    T value, {
    List<Object?>? capabilities,
  });

  /// Performs the [decode] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final decoded = codec.decode(pointerReader);
  /// ```
  T? decode(AnyPointerReader? reader);
}

/// Codec for callers that already have a serialized single-root message for a
/// generic value.
///
/// The payload is embedded preserving capability pointer words. RPC callers
/// should pass the matching capability table through the generated capability
/// argument APIs when using capability-bearing payloads.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class MessageAnyPointerCodec implements AnyPointerCodec<Uint8List> {
  /// Creates a [MessageAnyPointerCodec] instance.
  const MessageAnyPointerCodec();

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// codec.encode(builder, value);
  /// ```
  void encode(
    AnyPointerBuilder builder,
    Uint8List value, {
    List<Object?>? capabilities,
  }) {
    builder.setMessageBytes(value, preserveCapabilityPointers: true);
  }

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final decoded = codec.decode(pointerReader);
  /// ```
  Uint8List? decode(AnyPointerReader? reader) =>
      reader?.asMessageBytes(preserveCapabilityPointers: true);
}

/// Codec for generic values whose runtime representation is a struct reader.
///
/// This codec is primarily useful for decoding generic method results. For
/// encoding, prefer `StructBuilderAnyPointerCodec` so the value can be built in
/// the destination message.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class StructReaderAnyPointerCodec<
  R extends StructReader,
  B extends StructBuilder
>
    implements AnyPointerCodec<R> {
  /// Holds the public [factory] value.
  final StructFactory<R, B> factory;

  /// Creates a [StructReaderAnyPointerCodec] instance.
  const StructReaderAnyPointerCodec(this.factory);

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// reader.encode(builder, value);
  /// ```
  void encode(
    AnyPointerBuilder builder,
    R value, {
    List<Object?>? capabilities,
  }) {
    throw UnsupportedError(
      'StructReaderAnyPointerCodec only supports decoding values',
    );
  }

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final decoded = codec.decode(pointerReader);
  /// ```
  R? decode(AnyPointerReader? reader) => reader?.asStruct(factory);
}

/// Read-only view of an `AnyPointer` field.
///
/// The view keeps the message capability table next to the raw pointer. This
/// lets callers reinterpret capability-bearing payloads without degrading them
/// to plain bytes.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class AnyPointerReader {
  final RawStructReader _owner;
  final int _ptrIndex;
  final List<Object?> _capabilities;

  /// Creates a [AnyPointerReader] instance.
  const AnyPointerReader(
    this._owner,
    this._ptrIndex, {
    List<Object?> capabilities = const [],
  }) : _capabilities = capabilities;

  /// Returns the current [capabilityTable] value.
  List<Object?> get capabilityTable => _capabilities;

  /// Returns the current [isNull] value.
  bool get isNull {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) return true;
    return WirePointer.decode(
          _owner.segment.data,
          _owner.ptrWordOffset + _ptrIndex,
        )
        is NullPointer;
  }

  /// Performs the [asMessageBytes] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.asMessageBytes;
  /// ```
  Uint8List? asMessageBytes({bool preserveCapabilityPointers = false}) {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) return null;
    return copyAnyPointerToNewMessage(
      _owner,
      _ptrIndex,
      preserveCapabilityPointers: preserveCapabilityPointers,
    );
  }

  /// Reads the struct at this AnyPointer in place, without copying — same
  /// approach as [asDynamicStruct], just returning a typed [R] via
  /// [factory] instead of a schema-less [DynamicStructReader].
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.asStruct;
  /// ```
  R? asStruct<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory,
  ) {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) return null;
    final raw = _owner.arena.resolveOptionalStructAt(
      _owner.segment,
      _owner.ptrWordOffset + _ptrIndex,
      _owner.nestingLimit,
    );
    return raw == null
        ? null
        : factory.fromRawReaderWithCapabilities(raw, _capabilities);
  }

  /// Resolves the struct at this AnyPointer, treating an unset (null or
  /// out-of-range) pointer as an empty struct — the same convention
  /// [MessageReader.getRootRaw] uses for a message's root pointer. Unlike
  /// [asStruct]/[asStructWithCapabilities], never returns null; for callers
  /// (like RPC dispatch) that need to build their own reader — e.g. with a
  /// capabilities table not known until after this reader was constructed —
  /// without losing that "absent means default" convention.
  RawStructReader resolveStructOrEmpty() {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) {
      return RawStructReader(
        segment: _owner.segment,
        arena: _owner.arena,
        dataWordOffset: 0,
        dataWords: 0,
        ptrWordOffset: 0,
        ptrWords: 0,
        nestingLimit: _owner.nestingLimit,
      );
    }
    return _owner.arena.resolveStructAt(
      _owner.segment,
      _owner.ptrWordOffset + _ptrIndex,
      _owner.nestingLimit,
    );
  }

  /// Performs the [asDynamicStruct] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.asDynamicStruct;
  /// ```
  DynamicStructReader? asDynamicStruct() {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) return null;
    final raw = _owner.arena.resolveOptionalStructAt(
      _owner.segment,
      _owner.ptrWordOffset + _ptrIndex,
      _owner.nestingLimit,
    );
    return raw == null
        ? null
        : DynamicStructReader(raw, capabilities: _capabilities);
  }

  /// Performs this operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.asListWith;
  /// ```
  ListReader<T>? asListWith<T>(
    ListReader<T> Function(RawListReader raw, List<Object?> capabilities)
    fromRaw,
  ) {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) return null;
    final raw = _owner.arena.resolveListAt(
      _owner.segment,
      _owner.ptrWordOffset + _ptrIndex,
      _owner.nestingLimit,
    );
    if (raw == null) return null;
    return fromRaw(raw, _capabilities);
  }

  /// Performs the [asTextList] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.asTextList;
  /// ```
  ListReader<String?>? asTextList() =>
      asListWith((raw, _) => TextListReader(raw));

  /// Performs the [asDataList] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.asDataList;
  /// ```
  ListReader<Uint8List?>? asDataList() =>
      asListWith((raw, _) => DataListReader(raw));

  /// Performs this operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.asStructList;
  /// ```
  ListReader<R>? asStructList<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory,

    ///
    /// **Example**
    /// ```dart
    /// // Given the required message, schema, or raw-layout values:
    /// final operation = reader.asListWith;
    /// ```
  ) => asListWith(
    (raw, capabilities) => StructListReader<R>(
      raw,
      (r) => factory.fromRawReaderWithCapabilities(r, capabilities),
    ),
  );

  /// Performs the [asDynamicList] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.asDynamicList;
  /// ```
  DynamicListReader? asDynamicList() {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) return null;
    final raw = _owner.arena.resolveListAt(
      _owner.segment,
      _owner.ptrWordOffset + _ptrIndex,
      _owner.nestingLimit,
    );
    return raw == null
        ? null
        : DynamicListReader(raw, capabilities: _capabilities);
  }

  /// Returns the current [capabilityIndex] value.
  int get capabilityIndex {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) return -1;
    final ptr = WirePointer.decode(
      _owner.segment.data,
      _owner.ptrWordOffset + _ptrIndex,
    );
    if (ptr is NullPointer) return -1;
    if (ptr is CapabilityPointer) return ptr.capabilityIndex;
    throw DecodeException(
      'expected capability pointer, got ${ptr.runtimeType}',
    );
  }

  /// Performs the [asCapability] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = reader.asCapability;
  /// ```
  Object? asCapability() {
    final index = capabilityIndex;
    if (index < 0) return null;
    if (index >= _capabilities.length) {
      throw DecodeException(
        'capability table index $index is out of range for ${_capabilities.length} capabilities',
      );
    }
    final cap = _capabilities[index];
    if (cap == null) {
      throw DecodeException('capability table index $index is null');
    }
    return cap;
  }
}

/// Schema-less struct reader used by the dynamic API.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class DynamicStructReader extends StructReader {
  /// Creates a [DynamicStructReader] instance.
  DynamicStructReader(super.raw, {super.capabilities});

  /// Returns the current [dataWords] value.
  int get dataWords => raw.dataWords;

  /// Returns the current [pointerWords] value.
  int get pointerWords => raw.ptrWords;

  /// Performs the [getPointerField] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final fieldValue = reader.getPointerField(0);
  /// ```
  AnyPointerReader? getPointerField(int ptrIndex) =>
      getAnyPointerField(ptrIndex);

  /// Performs the [getStructField] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final fieldValue = reader.getStructField(0);
  /// ```
  DynamicStructReader? getStructField(int ptrIndex) =>
      getPointerField(ptrIndex)?.asDynamicStruct();

  /// Performs the [getListField] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final values = reader.getListField(0);
  /// ```
  DynamicListReader? getListField(int ptrIndex) =>
      getPointerField(ptrIndex)?.asDynamicList();

  /// Performs the [getCapabilityObject] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getCapabilityObject(0);
  /// ```
  Object? getCapabilityObject(int ptrIndex) =>
      getCapabilityObjectField(ptrIndex);
}

/// Schema-less list reader metadata used by the dynamic API.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class DynamicListReader {
  /// Holds the public [raw] value.
  final RawListReader raw;

  /// Holds the public [capabilities] value.
  final List<Object?> capabilities;

  /// Creates a [DynamicListReader] instance.
  const DynamicListReader(this.raw, {this.capabilities = const []});

  /// Returns the current [length] value.
  int get length => raw.elementCount;

  /// Returns the current [elementSize] value.
  ListElementSize get elementSize => raw.elementSize;

  /// Returns the current [structDataWords] value.
  int get structDataWords => raw.structDataWords;

  /// Returns the current [structPointerWords] value.
  int get structPointerWords => raw.structPtrWords;

  void _requireElementSize(ListElementSize expected) {
    if (raw.elementSize != expected) {
      throw DecodeException('expected $expected list, got ${raw.elementSize}');
    }
  }

  /// Performs the [getBool] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getBool(0);
  /// ```
  bool getBool(int index) {
    _requireElementSize(ListElementSize.bit);
    return BoolListReader(raw)[index];
  }

  /// Performs the [getInt8] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getInt8(0);
  /// ```
  int getInt8(int index) {
    _requireElementSize(ListElementSize.byte);
    return PrimitiveIntListReader(raw, readInt8, 1)[index];
  }

  /// Performs the [getUint8] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getUint8(0);
  /// ```
  int getUint8(int index) {
    _requireElementSize(ListElementSize.byte);
    return PrimitiveIntListReader(raw, readUint8, 1)[index];
  }

  /// Performs the [getInt16] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getInt16(0);
  /// ```
  int getInt16(int index) {
    _requireElementSize(ListElementSize.twoBytes);
    return PrimitiveIntListReader(raw, readInt16, 2)[index];
  }

  /// Performs the [getUint16] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getUint16(0);
  /// ```
  int getUint16(int index) {
    _requireElementSize(ListElementSize.twoBytes);
    return PrimitiveIntListReader(raw, readUint16, 2)[index];
  }

  /// Performs the [getInt32] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getInt32(0);
  /// ```
  int getInt32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveIntListReader(raw, readInt32, 4)[index];
  }

  /// Performs the [getUint32] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getUint32(0);
  /// ```
  int getUint32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveIntListReader(raw, readUint32, 4)[index];
  }

  /// Performs the [getInt64] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getInt64(0);
  /// ```
  int getInt64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveIntListReader(raw, readInt64, 8)[index];
  }

  /// Performs the [getUint64] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getUint64(0);
  /// ```
  int getUint64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveIntListReader(raw, readUint64, 8)[index];
  }

  /// Performs the [getFloat32] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getFloat32(0);
  /// ```
  double getFloat32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveDoubleListReader(raw, readFloat32, 4)[index];
  }

  /// Performs the [getFloat64] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getFloat64(0);
  /// ```
  double getFloat64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveDoubleListReader(raw, readFloat64, 8)[index];
  }

  /// Performs the [getText] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getText(0);
  /// ```
  String? getText(int index) {
    _requireElementSize(ListElementSize.pointer);
    return TextListReader(raw)[index];
  }

  /// Performs the [getData] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getData(0);
  /// ```
  Uint8List? getData(int index) {
    _requireElementSize(ListElementSize.pointer);
    return DataListReader(raw)[index];
  }

  /// Performs the [getCapabilityIndex] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getCapabilityIndex(0);
  /// ```
  int getCapabilityIndex(int index) {
    _requireElementSize(ListElementSize.pointer);
    return CapabilityListReader(raw)[index];
  }

  /// Performs the [getCapabilityObject] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getCapabilityObject(0);
  /// ```
  Object? getCapabilityObject(int index) {
    final capIndex = getCapabilityIndex(index);
    if (capIndex < 0) return null;
    if (capIndex >= capabilities.length) {
      throw DecodeException(
        'capability table index $capIndex is out of range for ${capabilities.length} capabilities',
      );
    }
    final cap = capabilities[capIndex];
    if (cap == null) {
      throw DecodeException('capability table index $capIndex is null');
    }
    return cap;
  }

  /// Performs the [getStruct] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getStruct(0);
  /// ```
  DynamicStructReader getStruct(int index) {
    RangeError.checkValidIndex(index, this);
    if (raw.elementSize != ListElementSize.composite) {
      throw DecodeException('expected composite list, got ${raw.elementSize}');
    }
    final stride = (raw.structDataWords + raw.structPtrWords) * bytesPerWord;
    final elementWordOffset =
        (raw.dataByteOffset + index * stride) ~/ bytesPerWord;
    return DynamicStructReader(
      RawStructReader(
        segment: raw.segment,
        arena: raw.arena,
        dataWordOffset: elementWordOffset,
        dataWords: raw.structDataWords,
        ptrWordOffset: elementWordOffset + raw.structDataWords,
        ptrWords: raw.structPtrWords,
        nestingLimit: raw.nestingLimit,
      ),
      capabilities: capabilities,
    );
  }

  /// Performs the [getList] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = reader.getList(0);
  /// ```
  DynamicListReader? getList(int index) {
    RangeError.checkValidIndex(index, this);
    if (raw.elementSize != ListElementSize.pointer) {
      throw DecodeException('expected pointer list, got ${raw.elementSize}');
    }
    final ptrWordOffset = raw.dataByteOffset ~/ bytesPerWord + index;
    final inner = raw.arena.resolveListAt(
      raw.segment,
      ptrWordOffset,
      raw.nestingLimit,
    );
    return inner == null
        ? null
        : DynamicListReader(inner, capabilities: capabilities);
  }
}

/// Schema-less struct builder used by the dynamic API.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class DynamicStructBuilder extends StructBuilder {
  /// Creates a [DynamicStructBuilder] instance.
  DynamicStructBuilder(super.raw);

  /// Returns the current [dataWords] value.
  int get dataWords => raw.dataWords;

  /// Returns the current [pointerWords] value.
  int get pointerWords => raw.ptrWords;

  @override
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = builder.asReader;
  /// ```
  DynamicStructReader asReader() => DynamicStructReader(rawToReader());

  /// Performs the [initPointerField] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final child = builder.initPointerField(0);
  /// ```
  AnyPointerBuilder initPointerField(int ptrIndex) =>
      initAnyPointerField(ptrIndex);
  // Callers of the dynamic API supply ptrIndex directly (unlike generated
  // code, where it's always a schema-verified offset), so it must be
  // validated before use — an out-of-range index would otherwise silently
  // write into whatever word follows this struct's pointer section.
  void _checkPointerIndex(int ptrIndex) {
    RangeError.checkValidIndex(ptrIndex, this, 'ptrIndex', raw.ptrWords);
  }

  /// Performs the [initDynamicStructField] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final child = builder.initDynamicStructField(0, dataWords: 1, pointerWords: 1);
  /// ```
  DynamicStructBuilder initDynamicStructField(
    int ptrIndex, {
    required int dataWords,
    required int pointerWords,
  }) {
    _checkPointerIndex(ptrIndex);
    return initStructFieldWith(
      ptrIndex,
      DynamicStructBuilder.new,
      dataWords,
      pointerWords,
    );
  }

  /// Performs the [initDynamicListField] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final values = builder.initDynamicListField(0, elementSize: ListElementSize.byte, count: 4);
  /// ```
  DynamicListBuilder initDynamicListField(
    int ptrIndex, {
    required ListElementSize elementSize,
    required int count,
    int structDataWords = 0,
    int structPointerWords = 0,
  }) {
    _checkPointerIndex(ptrIndex);
    final rawList = raw.arena.allocateList(
      ptrSeg: raw.segment,
      ptrWordOffset: raw.ptrWordOffset + ptrIndex,
      elementSize: elementSize,
      elementCount: count,
      structDataWords: structDataWords,
      structPtrWords: structPointerWords,
    );
    return DynamicListBuilder(rawList);
  }
}

/// Schema-less list builder used by the dynamic API.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class DynamicListBuilder {
  /// Holds the public [raw] value.
  final RawListBuilder raw;

  /// Creates a [DynamicListBuilder] instance.
  const DynamicListBuilder(this.raw);

  /// Returns the current [length] value.
  int get length => raw.elementCount;

  /// Returns the current [elementSize] value.
  ListElementSize get elementSize => raw.elementSize;

  /// Returns the current [structDataWords] value.
  int get structDataWords => raw.structDataWords;

  /// Returns the current [structPointerWords] value.
  int get structPointerWords => raw.structPtrWords;

  void _requireElementSize(ListElementSize expected) {
    if (raw.elementSize != expected) {
      throw DecodeException('expected $expected list, got ${raw.elementSize}');
    }
  }

  /// Performs the [getBool] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getBool(0);
  /// ```
  bool getBool(int index) {
    _requireElementSize(ListElementSize.bit);
    return BoolListBuilder(raw)[index];
  }

  /// Performs the [setBool] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setBool(0, true);
  /// ```
  void setBool(int index, bool value) {
    _requireElementSize(ListElementSize.bit);
    BoolListBuilder(raw)[index] = value;
  }

  /// Performs the [getInt8] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getInt8(0);
  /// ```
  int getInt8(int index) {
    _requireElementSize(ListElementSize.byte);
    return PrimitiveIntListBuilder(raw, readInt8, writeInt8, 1)[index];
  }

  /// Performs the [setInt8] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setInt8(0, 42);
  /// ```
  void setInt8(int index, int value) {
    _requireElementSize(ListElementSize.byte);
    PrimitiveIntListBuilder(raw, readInt8, writeInt8, 1)[index] = value;
  }

  /// Performs the [getUint8] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getUint8(0);
  /// ```
  int getUint8(int index) {
    _requireElementSize(ListElementSize.byte);
    return PrimitiveIntListBuilder(raw, readUint8, writeUint8, 1)[index];
  }

  /// Performs the [setUint8] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setUint8(0, 42);
  /// ```
  void setUint8(int index, int value) {
    _requireElementSize(ListElementSize.byte);
    PrimitiveIntListBuilder(raw, readUint8, writeUint8, 1)[index] = value;
  }

  /// Performs the [getInt16] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getInt16(0);
  /// ```
  int getInt16(int index) {
    _requireElementSize(ListElementSize.twoBytes);
    return PrimitiveIntListBuilder(raw, readInt16, writeInt16, 2)[index];
  }

  /// Performs the [setInt16] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setInt16(0, 42);
  /// ```
  void setInt16(int index, int value) {
    _requireElementSize(ListElementSize.twoBytes);
    PrimitiveIntListBuilder(raw, readInt16, writeInt16, 2)[index] = value;
  }

  /// Performs the [getUint16] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getUint16(0);
  /// ```
  int getUint16(int index) {
    _requireElementSize(ListElementSize.twoBytes);
    return PrimitiveIntListBuilder(raw, readUint16, writeUint16, 2)[index];
  }

  /// Performs the [setUint16] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setUint16(0, 42);
  /// ```
  void setUint16(int index, int value) {
    _requireElementSize(ListElementSize.twoBytes);
    PrimitiveIntListBuilder(raw, readUint16, writeUint16, 2)[index] = value;
  }

  /// Performs the [getInt32] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getInt32(0);
  /// ```
  int getInt32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveIntListBuilder(raw, readInt32, writeInt32, 4)[index];
  }

  /// Performs the [setInt32] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setInt32(0, 42);
  /// ```
  void setInt32(int index, int value) {
    _requireElementSize(ListElementSize.fourBytes);
    PrimitiveIntListBuilder(raw, readInt32, writeInt32, 4)[index] = value;
  }

  /// Performs the [getUint32] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getUint32(0);
  /// ```
  int getUint32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveIntListBuilder(raw, readUint32, writeUint32, 4)[index];
  }

  /// Performs the [setUint32] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setUint32(0, 42);
  /// ```
  void setUint32(int index, int value) {
    _requireElementSize(ListElementSize.fourBytes);
    PrimitiveIntListBuilder(raw, readUint32, writeUint32, 4)[index] = value;
  }

  /// Performs the [getInt64] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getInt64(0);
  /// ```
  int getInt64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveIntListBuilder(raw, readInt64, writeInt64, 8)[index];
  }

  /// Performs the [setInt64] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setInt64(0, 42);
  /// ```
  void setInt64(int index, int value) {
    _requireElementSize(ListElementSize.eightBytes);
    PrimitiveIntListBuilder(raw, readInt64, writeInt64, 8)[index] = value;
  }

  /// Performs the [getUint64] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getUint64(0);
  /// ```
  int getUint64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveIntListBuilder(raw, readUint64, writeUint64, 8)[index];
  }

  /// Performs the [setUint64] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setUint64(0, 42);
  /// ```
  void setUint64(int index, int value) {
    _requireElementSize(ListElementSize.eightBytes);
    PrimitiveIntListBuilder(raw, readUint64, writeUint64, 8)[index] = value;
  }

  /// Performs the [getFloat32] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getFloat32(0);
  /// ```
  double getFloat32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveDoubleListBuilder(raw, readFloat32, writeFloat32, 4)[index];
  }

  /// Performs the [setFloat32] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setFloat32(0, 1.5);
  /// ```
  void setFloat32(int index, double value) {
    _requireElementSize(ListElementSize.fourBytes);
    PrimitiveDoubleListBuilder(raw, readFloat32, writeFloat32, 4)[index] =
        value;
  }

  /// Performs the [getFloat64] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getFloat64(0);
  /// ```
  double getFloat64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveDoubleListBuilder(raw, readFloat64, writeFloat64, 8)[index];
  }

  /// Performs the [setFloat64] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setFloat64(0, 1.5);
  /// ```
  void setFloat64(int index, double value) {
    _requireElementSize(ListElementSize.eightBytes);
    PrimitiveDoubleListBuilder(raw, readFloat64, writeFloat64, 8)[index] =
        value;
  }

  /// Performs the [setText] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setText(0, 'hello');
  /// ```
  void setText(int index, String? value) {
    _requireElementSize(ListElementSize.pointer);
    TextListBuilder(raw)[index] = value;
  }

  /// Performs the [setData] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setData(0, Uint8List.fromList([1, 2, 3]));
  /// ```
  void setData(int index, Uint8List? value) {
    _requireElementSize(ListElementSize.pointer);
    DataListBuilder(raw)[index] = value;
  }

  /// Performs the [getCapabilityIndex] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getCapabilityIndex(0);
  /// ```
  int getCapabilityIndex(int index) {
    _requireElementSize(ListElementSize.pointer);
    return CapabilityListBuilder(raw)[index];
  }

  /// Performs the [setCapabilityIndex] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setCapabilityIndex(0, 42);
  /// ```
  void setCapabilityIndex(int index, int capTableIndex) {
    _requireElementSize(ListElementSize.pointer);
    CapabilityListBuilder(raw)[index] = capTableIndex;
  }

  /// Performs the [getStruct] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final result = builder.getStruct(0);
  /// ```
  DynamicStructBuilder getStruct(int index) {
    RangeError.checkValidIndex(index, this, 'index', raw.elementCount);
    if (raw.elementSize != ListElementSize.composite) {
      throw DecodeException('expected composite list, got ${raw.elementSize}');
    }
    final stride = (raw.structDataWords + raw.structPtrWords) * bytesPerWord;
    final elementWordOffset =
        (raw.dataByteOffset + index * stride) ~/ bytesPerWord;
    return DynamicStructBuilder(
      RawStructBuilder(
        segment: raw.segment,
        arena: raw.arena,
        dataWordOffset: elementWordOffset,
        dataWords: raw.structDataWords,
        ptrWordOffset: elementWordOffset + raw.structDataWords,
        ptrWords: raw.structPtrWords,
      ),
    );
  }

  /// Performs the [initList] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final values = builder.initList(0, elementSize: ListElementSize.byte, count: 4);
  /// ```
  DynamicListBuilder initList(
    int index, {
    required ListElementSize elementSize,
    required int count,
    int structDataWords = 0,
    int structPointerWords = 0,
  }) {
    RangeError.checkValidIndex(index, this, 'index', raw.elementCount);
    if (raw.elementSize != ListElementSize.pointer) {
      throw DecodeException('expected pointer list, got ${raw.elementSize}');
    }
    final ptrWordOffset = raw.dataByteOffset ~/ bytesPerWord + index;
    final inner = raw.arena.allocateList(
      ptrSeg: raw.segment,
      ptrWordOffset: ptrWordOffset,
      elementSize: elementSize,
      elementCount: count,
      structDataWords: structDataWords,
      structPtrWords: structPointerWords,
    );
    return DynamicListBuilder(inner);
  }
}

/// Writable view of an `AnyPointer` field.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class AnyPointerBuilder {
  final RawStructBuilder _owner;
  final int _ptrIndex;

  /// Generated code always passes a schema-verified `ptrIndex`, but the
  /// dynamic/reflection API (see [DynamicStructBuilder]) lets callers supply
  /// an arbitrary one — validate here so an out-of-range index fails loudly
  /// instead of silently corrupting whatever word follows this struct's
  /// pointer section in the segment.
  AnyPointerBuilder(this._owner, this._ptrIndex) {
    RangeError.checkValidIndex(_ptrIndex, _owner, 'ptrIndex', _owner.ptrWords);
  }

  RawListBuilder _allocateList(
    ListElementSize elementSize,
    int count, {
    int structDataWords = 0,
    int structPtrWords = 0,
  }) => _owner.arena.allocateList(
    ptrSeg: _owner.segment,
    ptrWordOffset: _owner.ptrWordOffset + _ptrIndex,
    elementSize: elementSize,
    elementCount: count,
    structDataWords: structDataWords,
    structPtrWords: structPtrWords,
  );

  /// Zeroes the pointer word, encoding it as Cap'n Proto's null pointer.
  ///
  /// Arena-allocated builders never reclaim space, so this cannot free
  /// whatever the slot previously pointed to — it only clears the pointer
  /// itself. That's enough to make subsequent reads see a null AnyPointer,
  /// matching normal Dart setter semantics for `= null`.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final operation = builder.clear;
  /// ```
  void clear() {
    const NullPointer().encode(
      _owner.segment.data,
      _owner.ptrWordOffset + _ptrIndex,
    );
  }

  /// [messageBytes] is re-parsed as its own standalone message; pass
  /// [options] with the limits appropriate for its source if it may be
  /// untrusted (see [StructBuilder.setAnyPointerFromMessage]).
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setMessageBytes(messageBytes);
  /// ```
  void setMessageBytes(
    Uint8List? messageBytes, {
    bool preserveCapabilityPointers = false,
    MessageReaderOptions options = const MessageReaderOptions(),
  }) {
    if (messageBytes == null) {
      clear();
      return;
    }
    copyMessageRootToBuilder(
      messageBytes,
      _owner.arena,
      _owner.segment,
      _owner.ptrWordOffset + _ptrIndex,
      preserveCapabilityPointers: preserveCapabilityPointers,
      options: options,
    );
  }

  /// Deep-copies the already-resolved struct [src] into this AnyPointer —
  /// like [setMessageBytes], but [src] is a [RawStructReader] already
  /// resolved from somewhere in memory (e.g. [StructBuilder.rawToReader]'s
  /// zero-copy view onto another builder's own in-progress content) rather
  /// than raw message bytes, so this skips the serialize-then-reparse round
  /// trip a bytes-based copy would need. See [copyStructToBuilder].
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setFromRawStruct(rawStructReader);
  /// ```
  void setFromRawStruct(
    RawStructReader src, {
    bool preserveCapabilityPointers = false,
  }) {
    copyStructToBuilder(
      src,
      _owner.arena,
      _owner.segment,
      _owner.ptrWordOffset + _ptrIndex,
      preserveCapabilityPointers: preserveCapabilityPointers,
    );
  }

  /// Performs the [setFromReader] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setFromReader(pointerReader);
  /// ```
  void setFromReader(
    AnyPointerReader? reader, {
    bool preserveCapabilityPointers = true,
  }) {
    if (reader == null) {
      clear();
      return;
    }
    setMessageBytes(
      reader.asMessageBytes(
        preserveCapabilityPointers: preserveCapabilityPointers,
      ),
      preserveCapabilityPointers: preserveCapabilityPointers,
    );
  }

  /// Performs the [setCapability] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// builder.setCapability(0);
  /// ```
  void setCapability(int capTableIndex) {
    CapabilityPointer(
      capabilityIndex: capTableIndex,
    ).encode(_owner.segment.data, _owner.ptrWordOffset + _ptrIndex);
  }

  /// Performs the [initTextList] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final values = builder.initTextList(4);
  /// ```
  ListBuilder<String?> initTextList(int count) =>
      TextListBuilder(_allocateList(ListElementSize.pointer, count));

  /// Performs the [initDataList] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final values = builder.initDataList(4);
  /// ```
  ListBuilder<Uint8List?> initDataList(int count) =>
      DataListBuilder(_allocateList(ListElementSize.pointer, count));

  /// Holds the raw list builder created by this operation.
  ListBuilder<B> initStructList<
    R extends StructReader,
    B extends StructBuilder
  >(StructFactory<R, B> factory, int count) => StructListBuilder<B>(
    _allocateList(
      ListElementSize.composite,
      count,
      structDataWords: factory.dataWords,
      structPtrWords: factory.ptrWords,
    ),
    factory.fromRawBuilder,
  );

  /// Performs this operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final child = builder.initStruct(myStructFactory);
  /// ```
  B initStruct<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory,
  ) {
    final raw = _owner.arena.allocateStruct(
      ptrSeg: _owner.segment,
      ptrWordOffset: _owner.ptrWordOffset + _ptrIndex,
      dataWords: factory.dataWords,
      ptrWords: factory.ptrWords,
    );
    return factory.fromRawBuilder(raw);
  }

  /// Reads back the content at this AnyPointer as an [AnyPointerReader], in
  /// place — no copy, no serialize/re-parse. Mirrors [StructBuilder.
  /// rawToReader]: the returned reader shares the same underlying buffer as
  /// this builder, so it reflects whatever has been written so far and any
  /// further writes through this builder remain visible through it.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final reader = builder.asReader();
  /// ```
  AnyPointerReader asReader({List<Object?> capabilities = const []}) =>
      AnyPointerReader(
        rawStructBuilderToReader(_owner),
        _ptrIndex,
        capabilities: capabilities,
      );

  /// Performs the [initDynamicStruct] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final child = builder.initDynamicStruct(dataWords: 1, pointerWords: 1);
  /// ```
  DynamicStructBuilder initDynamicStruct({
    required int dataWords,
    required int pointerWords,
  }) {
    final raw = _owner.arena.allocateStruct(
      ptrSeg: _owner.segment,
      ptrWordOffset: _owner.ptrWordOffset + _ptrIndex,
      dataWords: dataWords,
      ptrWords: pointerWords,
    );
    return DynamicStructBuilder(raw);
  }

  /// Performs the [initDynamicList] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final values = builder.initDynamicList(elementSize: ListElementSize.byte, count: 4);
  /// ```
  DynamicListBuilder initDynamicList({
    required ListElementSize elementSize,
    required int count,
    int structDataWords = 0,
    int structPointerWords = 0,
  }) {
    final raw = _owner.arena.allocateList(
      ptrSeg: _owner.segment,
      ptrWordOffset: _owner.ptrWordOffset + _ptrIndex,
      elementSize: elementSize,
      elementCount: count,
      structDataWords: structDataWords,
      structPtrWords: structPointerWords,
    );
    return DynamicListBuilder(raw);
  }
}
