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
import 'package:capnproto_dart/src/wire/pointer.dart';
import 'package:test/test.dart';

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
