import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/layout/any_pointer.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:capnproto_dart/src/message/message_copy.dart';
import 'package:capnproto_dart/src/message/message_reader.dart';
import 'package:capnproto_dart/src/message/message_reader_options.dart';
import 'package:capnproto_dart/src/wire/pointer.dart';
import 'package:capnproto_dart/src/wire/wire_helpers.dart';
import 'package:test/test.dart';

// Builds a 3-segment message whose root struct (dataWords=0, ptrWords=1) has
// a single pointer field reached via a double-far pointer:
//   Segment 0: [root struct ptr (dW=0, pW=1)] [double-far to seg1 word 0]
//   Segment 1: [single-far to seg2 word 0]     [list tag]
//   Segment 2: <list element data>
// Mirrors ArenaReaderTest's buildDoubleFarMessage, adapted so the far
// pointer sits behind a real root struct (matching anyHostFactory's shape)
// instead of being the message root itself.
Uint8List _buildDoubleFarListMessage({
  required WirePointer listTag,
  required List<int> dataBytes,
}) {
  final paddedLen = ((dataBytes.length + 7) ~/ bytesPerWord) * bytesPerWord;
  final paddedData = Uint8List(paddedLen)..setRange(0, dataBytes.length, dataBytes);
  final dataWords = paddedLen ~/ bytesPerWord;

  // 3 segments (odd) → header is 4 + 3×4 = 16 bytes, no padding word.
  final out = Uint8List(16 + (2 + 2 + dataWords) * bytesPerWord);
  final bd = ByteData.view(out.buffer);

  writeUint32(bd, 0, 2); // numSegments - 1 = 2
  writeUint32(bd, 4, 2); // seg0: 2 words (root struct ptr + its 1 ptr field)
  writeUint32(bd, 8, 2); // seg1: 2 words (single-far landing pad + list tag)
  writeUint32(bd, 12, dataWords); // seg2: element data

  final seg0 = ByteData.view(out.buffer, 16);
  StructPointer(offset: 0, dataWords: 0, ptrWords: 1).encode(seg0, 0);
  FarPointer(isDoubleFar: true, landingPadOffset: 0, segmentId: 1)
      .encode(seg0, 1);

  final seg1 = ByteData.view(out.buffer, 16 + 2 * bytesPerWord);
  FarPointer(isDoubleFar: false, landingPadOffset: 0, segmentId: 2)
      .encode(seg1, 0);
  listTag.encode(seg1, 1);

  out.setRange(16 + 4 * bytesPerWord, 16 + 4 * bytesPerWord + paddedLen,
      paddedData);

  return out;
}

class CapHolderReader extends StructReader {
  CapHolderReader(super.raw, {super.capabilities});

  int get capIndex => getCapabilityField(0);

  Object? get cap => getCapabilityObjectField(0);
}

class CapHolderBuilder extends StructBuilder {
  CapHolderBuilder(super.raw);

  set capIndex(int value) => setCapabilityField(0, value);

  @override
  CapHolderReader asReader() => throw UnimplementedError();
}

final capHolderFactory = _CapHolderFactory();

class _CapHolderFactory
    extends StructFactory<CapHolderReader, CapHolderBuilder> {
  @override
  int get dataWords => 0;

  @override
  int get ptrWords => 1;

  @override
  CapHolderReader fromRawReader(RawStructReader raw) => CapHolderReader(raw);

  @override
  CapHolderReader fromRawReaderWithCapabilities(
    RawStructReader raw,
    List<Object?> capabilities,
  ) => CapHolderReader(raw, capabilities: capabilities);

  @override
  CapHolderBuilder fromRawBuilder(RawStructBuilder raw) =>
      CapHolderBuilder(raw);
}

class AnyHostReader extends StructReader {
  AnyHostReader(super.raw, {super.capabilities});

  CapHolderReader? get payload =>
      getStructFieldWith(0, (raw) => CapHolderReader(raw));

  AnyPointerReader? get anyPayload => getAnyPointerField(0);

  Uint8List? get payloadBytesPreserving =>
      getAnyPointerAsMessageBytes(0, preserveCapabilityPointers: true);
}

class AnyHostBuilder extends StructBuilder {
  AnyHostBuilder(super.raw);

  AnyPointerBuilder initAnyPayload() => initAnyPointerField(0);

  set payloadBytes(Uint8List value) => setAnyPointerFromMessage(0, value);

  set payloadBytesPreserving(Uint8List value) =>
      setAnyPointerFromMessage(0, value, preserveCapabilityPointers: true);

  @override
  AnyHostReader asReader() => throw UnimplementedError();
}

final anyHostFactory = _AnyHostFactory();

class _AnyHostFactory extends StructFactory<AnyHostReader, AnyHostBuilder> {
  @override
  int get dataWords => 0;

  @override
  int get ptrWords => 1;

  @override
  AnyHostReader fromRawReader(RawStructReader raw) => AnyHostReader(raw);

  @override
  AnyHostReader fromRawReaderWithCapabilities(
    RawStructReader raw,
    List<Object?> capabilities,
  ) => AnyHostReader(raw, capabilities: capabilities);

  @override
  AnyHostBuilder fromRawBuilder(RawStructBuilder raw) => AnyHostBuilder(raw);
}

int _segmentCount(Uint8List bytes) =>
    ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.little) + 1;

Uint8List _buildLargeDataMessage(int size) {
  final data = Uint8List(size);
  for (var i = 0; i < data.length; i++) {
    data[i] = i & 0xff;
  }

  final builder = MessageBuilder();
  builder.initRoot(anyHostFactory).setDataField(0, data);
  final bytes = builder.serialize();
  expect(_segmentCount(bytes), greaterThan(1));
  return bytes;
}

void main() {
  group('bytes-only message copy', () {
    test(
      'ensureSingleSegment zeroes capability pointers in single-segment input',
      () {
        final sourceBuilder = MessageBuilder();
        sourceBuilder.initRoot(capHolderFactory).capIndex = 2;
        final sourceBytes = sourceBuilder.serialize();

        final sourceReader = MessageReader.deserialize(
          sourceBytes,
        ).getRoot(capHolderFactory);
        expect(sourceReader.capIndex, equals(2));

        final copiedBytes = ensureSingleSegment(sourceBytes);
        final copiedReader = MessageReader.deserialize(
          copiedBytes,
        ).getRoot(capHolderFactory);

        expect(copiedReader.capIndex, equals(-1));
      },
    );

    test(
      'ensureSingleSegment can preserve capability pointers with cap table',
      () {
        final sourceBuilder = MessageBuilder();
        sourceBuilder.initRoot(capHolderFactory).capIndex = 3;

        final copiedBytes = ensureSingleSegment(
          sourceBuilder.serialize(),
          preserveCapabilityPointers: true,
        );
        final copiedReader = MessageReader.deserialize(
          copiedBytes,
        ).getRoot(capHolderFactory);

        expect(copiedReader.capIndex, equals(3));
      },
    );

    test(
      'ensureSingleSegment flattens multi-segment messages semantically',
      () {
        final sourceBytes = _buildLargeDataMessage(10000);

        final copiedBytes = ensureSingleSegment(sourceBytes);
        final copiedReader = MessageReader.deserialize(
          copiedBytes,
        ).getRoot(anyHostFactory);

        expect(_segmentCount(copiedBytes), equals(1));
        expect(
          copiedReader.getDataField(0),
          orderedEquals(
            Uint8List.fromList(List<int>.generate(10000, (i) => i & 0xff)),
          ),
        );
      },
    );

    test(
      'ensureSingleSegment copies a Text field reached via a double-far pointer',
      () {
        // Regression test: the double-far branch of _copyPointer only
        // handled a struct-shaped landing pad tag; a list-shaped tag (Text,
        // Data, List(T)) fell through with no error, leaving the destination
        // pointer slot null instead of copying the list.
        final sourceBytes = _buildDoubleFarListMessage(
          listTag: const ListPointer(
            offset: 0,
            elementSize: ListElementSize.byte,
            elementCountOrWordCount: 6, // "hello\0"
          ),
          dataBytes: [0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x00],
        );

        final copiedBytes = ensureSingleSegment(sourceBytes);
        final copiedReader = MessageReader.deserialize(
          copiedBytes,
        ).getRoot(anyHostFactory);

        expect(copiedReader.getTextField(0), equals('hello'));
      },
    );

    test(
      'ensureSingleSegment copies a primitive List field reached via a '
      'double-far pointer',
      () {
        final sourceBytes = _buildDoubleFarListMessage(
          listTag: const ListPointer(
            offset: 0,
            elementSize: ListElementSize.fourBytes,
            elementCountOrWordCount: 2,
          ),
          dataBytes: [42, 0, 0, 0, 100, 0, 0, 0],
        );

        final copiedBytes = ensureSingleSegment(sourceBytes);
        final copiedArena = ArenaReader.fromBytes(
          copiedBytes,
          const MessageReaderOptions(),
        );
        final rootRaw = copiedArena.getRootRaw();
        final list = copiedArena.resolveListAt(
          rootRaw.segment,
          rootRaw.ptrWordOffset,
          rootRaw.nestingLimit,
        );

        expect(list, isNotNull);
        expect(list!.elementCount, equals(2));
        expect(
          readUint32(list.segment.data, list.dataByteOffset),
          equals(42),
        );
        expect(
          readUint32(list.segment.data, list.dataByteOffset + 4),
          equals(100),
        );
      },
    );

    test('raw AnyPointer import rejects multi-segment source today', () {
      final sourceBytes = _buildLargeDataMessage(10000);
      final arena = ArenaBuilder();
      final (ptrSeg, ptrWordOffset) = arena.allocate(1);

      expect(
        () => arena.writeAnyPointerFromMessage(
          ptrSeg,
          ptrWordOffset,
          sourceBytes,
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('multi-segment AnyPointer embedding'),
          ),
        ),
      );
    });

    test('setAnyPointerFromMessage embeds multi-segment source messages', () {
      final sourceBytes = _buildLargeDataMessage(10000);

      final hostBuilder = MessageBuilder();
      hostBuilder.initRoot(anyHostFactory).payloadBytes = sourceBytes;

      final hostReader = MessageReader.deserialize(
        hostBuilder.serialize(),
      ).getRoot(anyHostFactory);
      final embeddedRoot = hostReader.anyPayload!.asDynamicStruct()!;

      expect(
        embeddedRoot.getDataField(0),
        orderedEquals(
          Uint8List.fromList(List<int>.generate(10000, (i) => i & 0xff)),
        ),
      );
    });

    test(
      'AnyPointerBuilder.setMessageBytes embeds multi-segment source messages',
      () {
        final sourceBytes = _buildLargeDataMessage(10000);

        final hostBuilder = MessageBuilder();
        hostBuilder
            .initRoot(anyHostFactory)
            .initAnyPayload()
            .setMessageBytes(sourceBytes);

        final hostReader = MessageReader.deserialize(
          hostBuilder.serialize(),
        ).getRoot(anyHostFactory);
        final embeddedRoot = hostReader.anyPayload!.asDynamicStruct()!;

        expect(
          embeddedRoot.getDataField(0),
          orderedEquals(
            Uint8List.fromList(List<int>.generate(10000, (i) => i & 0xff)),
          ),
        );
      },
    );

    test(
      'setAnyPointerFromMessage does not embed dangling capability pointers',
      () {
        final sourceBuilder = MessageBuilder();
        sourceBuilder.initRoot(capHolderFactory).capIndex = 7;

        final hostBuilder = MessageBuilder();
        hostBuilder.initRoot(anyHostFactory).payloadBytes =
            sourceBuilder.serialize();

        final hostReader = MessageReader.deserialize(
          hostBuilder.serialize(),
        ).getRoot(anyHostFactory);

        expect(hostReader.payload, isNotNull);
        expect(hostReader.payload!.capIndex, equals(-1));
      },
    );

    test(
      'getAnyPointerAsMessageBytes can preserve capability pointers with cap table',
      () {
        final sourceBuilder = MessageBuilder();
        sourceBuilder.initRoot(capHolderFactory).capIndex = 11;

        final hostBuilder = MessageBuilder();
        hostBuilder.initRoot(anyHostFactory).payloadBytesPreserving =
            sourceBuilder.serialize();

        final hostReader = MessageReader.deserialize(
          hostBuilder.serialize(),
        ).getRoot(anyHostFactory);
        final extractedBytes = hostReader.payloadBytesPreserving!;
        final extractedReader = MessageReader.deserialize(
          extractedBytes,
        ).getRoot(capHolderFactory);

        expect(extractedReader.capIndex, equals(11));
      },
    );

    test('AnyPointerReader reinterprets payload as typed struct', () {
      final hostBuilder = MessageBuilder();
      final payload = hostBuilder
          .initRoot(anyHostFactory)
          .initAnyPayload()
          .initStruct(capHolderFactory);
      payload.capIndex = 0;

      final cap = Object();
      final hostReader = MessageReader.deserialize(
        hostBuilder.serialize(),
      ).getRoot(anyHostFactory, capabilities: [cap]);
      final any = hostReader.anyPayload;
      final typed = any!.asStruct(capHolderFactory);

      expect(typed, isNotNull);
      expect(typed!.capIndex, equals(0));
      expect(typed.cap, same(cap));
      expect(any.asDynamicStruct()!.getCapabilityObjectField(0), same(cap));
    });

    test('AnyPointerReader exposes direct capability pointers', () {
      final hostBuilder = MessageBuilder();
      hostBuilder.initRoot(anyHostFactory).initAnyPayload().setCapability(0);

      final cap = Object();
      final hostReader = MessageReader.deserialize(
        hostBuilder.serialize(),
      ).getRoot(anyHostFactory, capabilities: [cap]);
      final any = hostReader.anyPayload;

      expect(any, isNotNull);
      expect(any!.capabilityIndex, equals(0));
      expect(any.asCapability(), same(cap));
    });

    test(
      'copyAnyPointerToNewMessage preserves top-level capability pointer',
      () {
        final hostBuilder = MessageBuilder();
        hostBuilder.initRoot(anyHostFactory).initAnyPayload().setCapability(4);

        final hostReader = MessageReader.deserialize(
          hostBuilder.serialize(),
        ).getRoot(anyHostFactory);

        expect(hostReader.anyPayload!.asMessageBytes(), isNull);

        final copiedBytes = hostReader.anyPayload!.asMessageBytes(
          preserveCapabilityPointers: true,
        );
        expect(copiedBytes, isNotNull);

        final segmentData = ByteData.sublistView(copiedBytes!, 8);
        final rootPointer = WirePointer.decode(segmentData, 0);
        expect(rootPointer, isA<CapabilityPointer>());
        expect((rootPointer as CapabilityPointer).capabilityIndex, equals(4));
      },
    );

    test('dynamic struct API reads and writes data and pointer fields', () {
      final hostBuilder = MessageBuilder();
      final dynamicStruct = hostBuilder
          .initRoot(anyHostFactory)
          .initAnyPayload()
          .initDynamicStruct(dataWords: 1, pointerWords: 1);
      dynamicStruct.setInt32Field(0, 12345);
      dynamicStruct.setTextField(0, 'dynamic text');

      final hostReader = MessageReader.deserialize(
        hostBuilder.serialize(),
      ).getRoot(anyHostFactory);
      final dynamicReader = hostReader.anyPayload!.asDynamicStruct();

      expect(dynamicReader, isNotNull);
      expect(dynamicReader!.dataWords, equals(1));
      expect(dynamicReader.pointerWords, equals(1));
      expect(dynamicReader.getInt32Field(0), equals(12345));
      expect(dynamicReader.getTextField(0), equals('dynamic text'));
    });

    test('dynamic list API reads primitive, composite, and nested lists', () {
      final primitiveHost = MessageBuilder();
      final primitiveList = primitiveHost
          .initRoot(anyHostFactory)
          .initAnyPayload()
          .initDynamicList(elementSize: ListElementSize.fourBytes, count: 2);
      primitiveList.setInt32(0, 10);
      primitiveList.setInt32(1, 20);
      final primitiveReader =
          MessageReader.deserialize(
            primitiveHost.serialize(),
          ).getRoot(anyHostFactory).anyPayload!.asDynamicList();
      expect(primitiveReader!.length, equals(2));
      expect(primitiveReader.getInt32(1), equals(20));

      final compositeHost = MessageBuilder();
      final compositeList = compositeHost
          .initRoot(anyHostFactory)
          .initAnyPayload()
          .initDynamicList(
            elementSize: ListElementSize.composite,
            count: 1,
            structDataWords: 1,
            structPointerWords: 1,
          );
      compositeList.getStruct(0)
        ..setUint16Field(0, 77)
        ..setTextField(0, 'element');
      final compositeReader =
          MessageReader.deserialize(
            compositeHost.serialize(),
          ).getRoot(anyHostFactory).anyPayload!.asDynamicList();
      final element = compositeReader!.getStruct(0);
      expect(element.getUint16Field(0), equals(77));
      expect(element.getTextField(0), equals('element'));

      final nestedHost = MessageBuilder();
      final outer = nestedHost
          .initRoot(anyHostFactory)
          .initAnyPayload()
          .initDynamicList(elementSize: ListElementSize.pointer, count: 1);
      outer.initList(0, elementSize: ListElementSize.twoBytes, count: 2)
        ..setUint16(0, 11)
        ..setUint16(1, 22);
      final nestedReader =
          MessageReader.deserialize(
            nestedHost.serialize(),
          ).getRoot(anyHostFactory).anyPayload!.asDynamicList();
      expect(nestedReader!.getList(0)!.getUint16(1), equals(22));
    });

    test('message copy preserves List(Void) element count', () {
      final source = MessageBuilder();
      source
          .initRoot(anyHostFactory)
          .initAnyPayload()
          .initDynamicList(elementSize: ListElementSize.void_, count: 5);

      final copied = ensureSingleSegment(source.serialize());
      final reader =
          MessageReader.deserialize(
            copied,
          ).getRoot(anyHostFactory).anyPayload!.asDynamicList();

      expect(reader, isNotNull);
      expect(reader!.length, equals(5));
    });
  });
}
