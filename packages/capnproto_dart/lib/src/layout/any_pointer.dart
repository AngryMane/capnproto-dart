import 'dart:typed_data';

import '../arena/arena_builder.dart';
import '../arena/arena_reader.dart';
import '../exception/decode_exception.dart';
import '../message/message_copy.dart';
import '../message/message_reader.dart';
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
abstract interface class AnyPointerCodec<T> {
  void encode(
    AnyPointerBuilder builder,
    T value, {
    List<Object?>? capabilities,
  });

  T? decode(AnyPointerReader? reader);
}

/// Codec for callers that already have a serialized single-root message for a
/// generic value.
///
/// The payload is embedded preserving capability pointer words. RPC callers
/// should pass the matching capability table through the generated capability
/// argument APIs when using capability-bearing payloads.
final class MessageAnyPointerCodec implements AnyPointerCodec<Uint8List> {
  const MessageAnyPointerCodec();

  @override
  void encode(
    AnyPointerBuilder builder,
    Uint8List value, {
    List<Object?>? capabilities,
  }) {
    builder.setMessageBytes(value, preserveCapabilityPointers: true);
  }

  @override
  Uint8List? decode(AnyPointerReader? reader) =>
      reader?.asMessageBytes(preserveCapabilityPointers: true);
}

/// Codec for generic values whose runtime representation is a struct reader.
///
/// This codec is primarily useful for decoding generic method results. For
/// encoding, prefer [StructBuilderAnyPointerCodec] so the value can be built in
/// the destination message.
final class StructReaderAnyPointerCodec<
  R extends StructReader,
  B extends StructBuilder
>
    implements AnyPointerCodec<R> {
  final StructFactory<R, B> factory;

  const StructReaderAnyPointerCodec(this.factory);

  @override
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
  R? decode(AnyPointerReader? reader) => reader?.asStruct(factory);
}

/// Read-only view of an `AnyPointer` field.
///
/// The view keeps the message capability table next to the raw pointer. This
/// lets callers reinterpret capability-bearing payloads without degrading them
/// to plain bytes.
final class AnyPointerReader {
  final RawStructReader _owner;
  final int _ptrIndex;
  final List<Object?> _capabilities;

  const AnyPointerReader(
    this._owner,
    this._ptrIndex, {
    List<Object?> capabilities = const [],
  }) : _capabilities = capabilities;

  List<Object?> get capabilityTable => _capabilities;

  bool get isNull {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) return true;
    return WirePointer.decode(
          _owner.segment.data,
          _owner.ptrWordOffset + _ptrIndex,
        )
        is NullPointer;
  }

  Uint8List? asMessageBytes({bool preserveCapabilityPointers = false}) {
    if (_ptrIndex < 0 || _ptrIndex >= _owner.ptrWords) return null;
    return copyAnyPointerToNewMessage(
      _owner,
      _ptrIndex,
      preserveCapabilityPointers: preserveCapabilityPointers,
    );
  }

  R? asStruct<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory,
  ) {
    final bytes = asMessageBytes(preserveCapabilityPointers: true);
    if (bytes == null) return null;
    return MessageReader.deserialize(
      bytes,
    ).getRoot(factory, capabilities: _capabilities);
  }

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

  ListReader<String?>? asTextList() =>
      asListWith((raw, _) => TextListReader(raw));

  ListReader<Uint8List?>? asDataList() =>
      asListWith((raw, _) => DataListReader(raw));

  ListReader<R>? asStructList<R extends StructReader, B extends StructBuilder>(
    StructFactory<R, B> factory,
  ) => asListWith(
    (raw, capabilities) => StructListReader<R>(
      raw,
      (r) => factory.fromRawReaderWithCapabilities(r, capabilities),
    ),
  );

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
final class DynamicStructReader extends StructReader {
  DynamicStructReader(super.raw, {super.capabilities});

  int get dataWords => raw.dataWords;

  int get pointerWords => raw.ptrWords;

  AnyPointerReader? getPointerField(int ptrIndex) =>
      getAnyPointerField(ptrIndex);

  DynamicStructReader? getStructField(int ptrIndex) =>
      getPointerField(ptrIndex)?.asDynamicStruct();

  DynamicListReader? getListField(int ptrIndex) =>
      getPointerField(ptrIndex)?.asDynamicList();

  Object? getCapabilityObject(int ptrIndex) =>
      getCapabilityObjectField(ptrIndex);
}

/// Schema-less list reader metadata used by the dynamic API.
final class DynamicListReader {
  final RawListReader raw;
  final List<Object?> capabilities;

  const DynamicListReader(this.raw, {this.capabilities = const []});

  int get length => raw.elementCount;

  ListElementSize get elementSize => raw.elementSize;

  int get structDataWords => raw.structDataWords;

  int get structPointerWords => raw.structPtrWords;

  void _requireElementSize(ListElementSize expected) {
    if (raw.elementSize != expected) {
      throw DecodeException(
        'expected $expected list, got ${raw.elementSize}',
      );
    }
  }

  bool getBool(int index) {
    _requireElementSize(ListElementSize.bit);
    return BoolListReader(raw)[index];
  }

  int getInt8(int index) {
    _requireElementSize(ListElementSize.byte);
    return PrimitiveIntListReader(raw, readInt8, 1)[index];
  }

  int getUint8(int index) {
    _requireElementSize(ListElementSize.byte);
    return PrimitiveIntListReader(raw, readUint8, 1)[index];
  }

  int getInt16(int index) {
    _requireElementSize(ListElementSize.twoBytes);
    return PrimitiveIntListReader(raw, readInt16, 2)[index];
  }

  int getUint16(int index) {
    _requireElementSize(ListElementSize.twoBytes);
    return PrimitiveIntListReader(raw, readUint16, 2)[index];
  }

  int getInt32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveIntListReader(raw, readInt32, 4)[index];
  }

  int getUint32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveIntListReader(raw, readUint32, 4)[index];
  }

  int getInt64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveIntListReader(raw, readInt64, 8)[index];
  }

  int getUint64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveIntListReader(raw, readUint64, 8)[index];
  }

  double getFloat32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveDoubleListReader(raw, readFloat32, 4)[index];
  }

  double getFloat64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveDoubleListReader(raw, readFloat64, 8)[index];
  }

  String? getText(int index) {
    _requireElementSize(ListElementSize.pointer);
    return TextListReader(raw)[index];
  }

  Uint8List? getData(int index) {
    _requireElementSize(ListElementSize.pointer);
    return DataListReader(raw)[index];
  }

  int getCapabilityIndex(int index) {
    _requireElementSize(ListElementSize.pointer);
    return CapabilityListReader(raw)[index];
  }

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
final class DynamicStructBuilder extends StructBuilder {
  DynamicStructBuilder(super.raw);

  int get dataWords => raw.dataWords;

  int get pointerWords => raw.ptrWords;

  @override
  DynamicStructReader asReader() => DynamicStructReader(rawToReader());

  AnyPointerBuilder initPointerField(int ptrIndex) =>
      initAnyPointerField(ptrIndex);

  // Callers of the dynamic API supply ptrIndex directly (unlike generated
  // code, where it's always a schema-verified offset), so it must be
  // validated before use — an out-of-range index would otherwise silently
  // write into whatever word follows this struct's pointer section.
  void _checkPointerIndex(int ptrIndex) {
    RangeError.checkValidIndex(ptrIndex, this, 'ptrIndex', raw.ptrWords);
  }

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
final class DynamicListBuilder {
  final RawListBuilder raw;

  const DynamicListBuilder(this.raw);

  int get length => raw.elementCount;

  ListElementSize get elementSize => raw.elementSize;

  int get structDataWords => raw.structDataWords;

  int get structPointerWords => raw.structPtrWords;

  void _requireElementSize(ListElementSize expected) {
    if (raw.elementSize != expected) {
      throw DecodeException(
        'expected $expected list, got ${raw.elementSize}',
      );
    }
  }

  bool getBool(int index) {
    _requireElementSize(ListElementSize.bit);
    return BoolListBuilder(raw)[index];
  }

  void setBool(int index, bool value) {
    _requireElementSize(ListElementSize.bit);
    BoolListBuilder(raw)[index] = value;
  }

  int getInt8(int index) {
    _requireElementSize(ListElementSize.byte);
    return PrimitiveIntListBuilder(raw, readInt8, writeInt8, 1)[index];
  }

  void setInt8(int index, int value) {
    _requireElementSize(ListElementSize.byte);
    PrimitiveIntListBuilder(raw, readInt8, writeInt8, 1)[index] = value;
  }

  int getUint8(int index) {
    _requireElementSize(ListElementSize.byte);
    return PrimitiveIntListBuilder(raw, readUint8, writeUint8, 1)[index];
  }

  void setUint8(int index, int value) {
    _requireElementSize(ListElementSize.byte);
    PrimitiveIntListBuilder(raw, readUint8, writeUint8, 1)[index] = value;
  }

  int getInt16(int index) {
    _requireElementSize(ListElementSize.twoBytes);
    return PrimitiveIntListBuilder(raw, readInt16, writeInt16, 2)[index];
  }

  void setInt16(int index, int value) {
    _requireElementSize(ListElementSize.twoBytes);
    PrimitiveIntListBuilder(raw, readInt16, writeInt16, 2)[index] = value;
  }

  int getUint16(int index) {
    _requireElementSize(ListElementSize.twoBytes);
    return PrimitiveIntListBuilder(raw, readUint16, writeUint16, 2)[index];
  }

  void setUint16(int index, int value) {
    _requireElementSize(ListElementSize.twoBytes);
    PrimitiveIntListBuilder(raw, readUint16, writeUint16, 2)[index] = value;
  }

  int getInt32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveIntListBuilder(raw, readInt32, writeInt32, 4)[index];
  }

  void setInt32(int index, int value) {
    _requireElementSize(ListElementSize.fourBytes);
    PrimitiveIntListBuilder(raw, readInt32, writeInt32, 4)[index] = value;
  }

  int getUint32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveIntListBuilder(raw, readUint32, writeUint32, 4)[index];
  }

  void setUint32(int index, int value) {
    _requireElementSize(ListElementSize.fourBytes);
    PrimitiveIntListBuilder(raw, readUint32, writeUint32, 4)[index] = value;
  }

  int getInt64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveIntListBuilder(raw, readInt64, writeInt64, 8)[index];
  }

  void setInt64(int index, int value) {
    _requireElementSize(ListElementSize.eightBytes);
    PrimitiveIntListBuilder(raw, readInt64, writeInt64, 8)[index] = value;
  }

  int getUint64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveIntListBuilder(raw, readUint64, writeUint64, 8)[index];
  }

  void setUint64(int index, int value) {
    _requireElementSize(ListElementSize.eightBytes);
    PrimitiveIntListBuilder(raw, readUint64, writeUint64, 8)[index] = value;
  }

  double getFloat32(int index) {
    _requireElementSize(ListElementSize.fourBytes);
    return PrimitiveDoubleListBuilder(raw, readFloat32, writeFloat32, 4)[index];
  }

  void setFloat32(int index, double value) {
    _requireElementSize(ListElementSize.fourBytes);
    PrimitiveDoubleListBuilder(raw, readFloat32, writeFloat32, 4)[index] =
        value;
  }

  double getFloat64(int index) {
    _requireElementSize(ListElementSize.eightBytes);
    return PrimitiveDoubleListBuilder(raw, readFloat64, writeFloat64, 8)[index];
  }

  void setFloat64(int index, double value) {
    _requireElementSize(ListElementSize.eightBytes);
    PrimitiveDoubleListBuilder(raw, readFloat64, writeFloat64, 8)[index] =
        value;
  }

  void setText(int index, String? value) {
    _requireElementSize(ListElementSize.pointer);
    TextListBuilder(raw)[index] = value;
  }

  void setData(int index, Uint8List? value) {
    _requireElementSize(ListElementSize.pointer);
    DataListBuilder(raw)[index] = value;
  }

  int getCapabilityIndex(int index) {
    _requireElementSize(ListElementSize.pointer);
    return CapabilityListBuilder(raw)[index];
  }

  void setCapabilityIndex(int index, int capTableIndex) {
    _requireElementSize(ListElementSize.pointer);
    CapabilityListBuilder(raw)[index] = capTableIndex;
  }

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
final class AnyPointerBuilder {
  final RawStructBuilder _owner;
  final int _ptrIndex;

  /// Generated code always passes a schema-verified [ptrIndex], but the
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
  void clear() {
    const NullPointer().encode(
      _owner.segment.data,
      _owner.ptrWordOffset + _ptrIndex,
    );
  }

  /// [messageBytes] is re-parsed as its own standalone message; pass
  /// [options] with the limits appropriate for its source if it may be
  /// untrusted (see [StructBuilder.setAnyPointerFromMessage]).
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

  void setCapability(int capTableIndex) {
    CapabilityPointer(
      capabilityIndex: capTableIndex,
    ).encode(_owner.segment.data, _owner.ptrWordOffset + _ptrIndex);
  }

  ListBuilder<String?> initTextList(int count) =>
      TextListBuilder(_allocateList(ListElementSize.pointer, count));

  ListBuilder<Uint8List?> initDataList(int count) =>
      DataListBuilder(_allocateList(ListElementSize.pointer, count));

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
