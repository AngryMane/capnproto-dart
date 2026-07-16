import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:capnproto_dart/src/message/message_copy.dart';
import 'package:capnproto_dart/src/message/message_reader.dart';
import 'package:test/test.dart';

class CapHolderReader extends StructReader {
  CapHolderReader(super.raw);

  int get capIndex => getCapabilityField(0);
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
  CapHolderBuilder fromRawBuilder(RawStructBuilder raw) =>
      CapHolderBuilder(raw);
}

class AnyHostReader extends StructReader {
  AnyHostReader(super.raw);

  CapHolderReader? get payload =>
      getStructFieldWith(0, (raw) => CapHolderReader(raw));

  Uint8List? get payloadBytesPreserving =>
      getAnyPointerAsMessageBytes(0, preserveCapabilityPointers: true);
}

class AnyHostBuilder extends StructBuilder {
  AnyHostBuilder(super.raw);

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
  });
}
