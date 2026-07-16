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
  });
}
