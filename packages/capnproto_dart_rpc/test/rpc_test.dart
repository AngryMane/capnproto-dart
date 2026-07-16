import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_proto.dart';
import 'package:capnproto_dart_rpc/src/rpc/two_party_connection.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Minimal in-memory schema: Echo interface
//   method echo(message :Text) -> (reply :Text)
//   interfaceId = 0x0001
//   methodId = 0
// ---------------------------------------------------------------------------

const int _echoInterfaceId = 0x0001;
const int _echoMethodId = 0;
const int _pipelineMethodId = 1; // returns a capability in caps[0]
const int _mixedMethodId = 2; // result has non-cap at slot 0, cap at slot 1
const int _duplicateCapsMethodId = 3; // returns the same cap in two slots
const int _largeCapResultMethodId = 4; // result has large data + cap
const int _largeCapParamMethodId = 5; // params have large data + cap

// Simple factory to build param message { message :Text } (ptr 0)
Uint8List _buildEchoParams(String message) {
  final mb = MessageBuilder();
  final root = mb.initRoot(_TextParamFactory());
  root.setTextField(0, message);
  return mb.serialize();
}

String? _parseEchoResult(Uint8List bytes) {
  final mr = MessageReader.deserialize(bytes);
  final root = mr.getRoot(_TextParamFactory());
  return root.getTextField(0);
}

int _segmentCount(Uint8List bytes) =>
    ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.little) + 1;

Uint8List _largeData(int size) =>
    Uint8List.fromList(List<int>.generate(size, (i) => i & 0xff));

Uint8List _buildLargeDataParams(int size) {
  final mb = MessageBuilder();
  mb.initRoot(_TextParamFactory()).setDataField(0, _largeData(size));
  final bytes = mb.serialize();
  expect(_segmentCount(bytes), greaterThan(1));
  return bytes;
}

Uint8List _buildLargeDataAndCapResult(int size) {
  final mb = MessageBuilder();
  final root = mb.initRoot(_TwoPtrFactory());
  root.setDataField(0, _largeData(size));
  root.setCapabilityField(1, 0);
  final bytes = mb.serialize();
  expect(_segmentCount(bytes), greaterThan(1));
  return bytes;
}

// A minimal StructFactory for a struct with 0 dataWords and 1 ptrWord (Text).
final class _TextParamFactory
    extends StructFactory<_TextParamReader, _TextParamBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 1;
  @override
  _TextParamReader fromRawReader(RawStructReader r) => _TextParamReader(r);
  @override
  _TextParamBuilder fromRawBuilder(RawStructBuilder r) => _TextParamBuilder(r);
}

// A struct factory with 0 dataWords and 2 ptrWords (for mixed-result tests).
final class _TwoPtrFactory
    extends StructFactory<_TextParamReader, _TextParamBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 2;
  @override
  _TextParamReader fromRawReader(RawStructReader r) => _TextParamReader(r);
  @override
  _TextParamBuilder fromRawBuilder(RawStructBuilder r) => _TextParamBuilder(r);
}

class _TextParamReader extends StructReader {
  _TextParamReader(super.raw);
}

class _TextParamBuilder extends StructBuilder {
  _TextParamBuilder(super.raw);
  @override
  StructReader asReader() => throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Echo server implementation
// ---------------------------------------------------------------------------

class EchoServer extends Capability {
  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (interfaceId != _echoInterfaceId) {
      throw RpcException('wrong interface: $interfaceId');
    }
    if (methodId != _echoMethodId) {
      throw RpcException('unknown method: $methodId');
    }

    final mr = MessageReader.deserialize(params);
    final req = mr.getRoot(_TextParamFactory());
    final message = req.getTextField(0) ?? '';
    return DispatchResult(bytes: _buildEchoParams('echo: $message'));
  }

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// Echo client stub
// ---------------------------------------------------------------------------

class EchoClient extends Capability {
  final Capability cap;
  EchoClient(this.cap);

  Future<String> echo(String message) async {
    final result = await cap.dispatch(
      _echoInterfaceId,
      _echoMethodId,
      _buildEchoParams(message),
    );
    return _parseEchoResult(result.bytes) ?? '';
  }

  @override
  Future<DispatchResult> dispatch(
    int iid,
    int mid,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => Future.error(UnsupportedError('client stub'));

  @override
  Future<void> dispose() => cap.dispose();
}

class EchoClientFactory extends CapabilityFactory<EchoClient> {
  @override
  EchoClient fromCapability(Capability cap) => EchoClient(cap);
}

// ---------------------------------------------------------------------------
// In-memory pipe helper
// ---------------------------------------------------------------------------

/// Creates a bidirectional in-memory pipe: returns (client conn, server conn).
(TwoPartyRpcConnection, TwoPartyRpcConnection) _makePipe(
  Capability serverBootstrap,
) {
  final clientToServer = StreamController<Uint8List>();
  final serverToClient = StreamController<Uint8List>();

  final client = TwoPartyRpcConnection.client(
    incoming: serverToClient.stream,
    outgoing: clientToServer.sink,
  );
  final server = TwoPartyRpcConnection.server(
    incoming: clientToServer.stream,
    outgoing: serverToClient.sink,
    bootstrap: serverBootstrap,
  );
  return (client, server);
}

// ---------------------------------------------------------------------------
// PipelineServer — method 1 returns itself as caps[0] for pipelining tests
// ---------------------------------------------------------------------------

class PipelineServer extends Capability {
  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (methodId == _echoMethodId) {
      final mr = MessageReader.deserialize(params);
      final message = mr.getRoot(_TextParamFactory()).getTextField(0) ?? '';
      return DispatchResult(bytes: _buildEchoParams('echo: $message'));
    }
    if (methodId == _pipelineMethodId) {
      // Result struct: 1 pointer slot.
      // slot 0: CapabilityPointer(capTableIndex=0) → caps[0] = this server.
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory()).setCapabilityField(0, 0);
      return DispatchResult(bytes: mb.serialize(), caps: [this]);
    }
    throw RpcException('unknown method: $methodId');
  }

  @override
  Future<void> dispose() async {}
}

// MixedResultServer: method 2 returns a result struct with 2 pointer slots
// where slot 0 is NOT a capability and slot 1 IS a capability (cap table index 0).
// This is the scenario that exposed the RPC-001 bug (ptrIndex ≠ capTableIndex).
class MixedResultServer extends Capability {
  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (methodId == _echoMethodId) {
      final mr = MessageReader.deserialize(params);
      final message = mr.getRoot(_TextParamFactory()).getTextField(0) ?? '';
      return DispatchResult(bytes: _buildEchoParams('echo: $message'));
    }
    if (methodId == _mixedMethodId) {
      // Result struct: 2 pointer slots.
      // slot 0: null (not a capability)
      // slot 1: CapabilityPointer(capTableIndex=0) → caps[0] = this server.
      final mb = MessageBuilder();
      mb.initRoot(_TwoPtrFactory()).setCapabilityField(1, 0);
      return DispatchResult(bytes: mb.serialize(), caps: [this]);
    }
    throw RpcException('unknown method: $methodId');
  }

  @override
  Future<void> dispose() async {}
}

class ChildPipelineServer extends Capability {
  final Completer<void>? completer;
  final Capability child = EchoServer();

  ChildPipelineServer({this.completer});

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (methodId == _pipelineMethodId) {
      final c = completer;
      if (c != null) await c.future;
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory()).setCapabilityField(0, 0);
      return DispatchResult(bytes: mb.serialize(), caps: [child]);
    }
    if (methodId == _echoMethodId) {
      return DispatchResult(bytes: _buildEchoParams('ok'));
    }
    throw RpcException('unknown method: $methodId');
  }

  @override
  Future<void> dispose() async {}
}

class DuplicateCapsServer extends Capability {
  final Capability child = EchoServer();

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (methodId == _duplicateCapsMethodId) {
      final mb = MessageBuilder();
      final root = mb.initRoot(_TwoPtrFactory());
      root.setCapabilityField(0, 0);
      root.setCapabilityField(1, 1);
      return DispatchResult(bytes: mb.serialize(), caps: [child, child]);
    }
    if (methodId == _echoMethodId) {
      return DispatchResult(bytes: _buildEchoParams('ok'));
    }
    throw RpcException('unknown method: $methodId');
  }

  @override
  Future<void> dispose() async {}
}

class LargeCapabilityPayloadServer extends Capability {
  final Capability child = EchoServer();
  int? lastDataLength;
  String? lastParamCapReply;

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (methodId == _largeCapResultMethodId) {
      return DispatchResult(
        bytes: _buildLargeDataAndCapResult(10000),
        caps: [child],
      );
    }

    if (methodId == _largeCapParamMethodId) {
      final root = MessageReader.deserialize(params).getRoot(_TwoPtrFactory());
      lastDataLength = root.getDataField(0)?.length;
      final cap = root.getCapabilityField(1);
      if (cap != 0 || paramsCapabilities.isEmpty) {
        throw RpcException('large cap param did not carry capability');
      }
      final reply = await paramsCapabilities[0].dispatch(
        _echoInterfaceId,
        _echoMethodId,
        _buildEchoParams('from server'),
      );
      lastParamCapReply = _parseEchoResult(reply.bytes);
      return DispatchResult(bytes: _buildEchoParams('ok'));
    }

    if (methodId == _echoMethodId) {
      return DispatchResult(bytes: _buildEchoParams('ok'));
    }

    throw RpcException('unknown method: $methodId');
  }

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// CapReceivingServer — captures paramsCapabilities for inspection
// ---------------------------------------------------------------------------

class CapReceivingServer extends Capability {
  List<Capability> lastParams = const [];

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    lastParams = List.of(paramsCapabilities);
    return DispatchResult(bytes: _buildEchoParams('ok'));
  }

  @override
  Future<void> dispose() async {}
}

class SlowEchoServer extends Capability {
  final Completer<void> started = Completer<void>();
  final Completer<void> canceled = Completer<void>();
  final Completer<void> complete = Completer<void>();
  DispatchContext? lastContext;

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (!started.isCompleted) started.complete();
    await complete.future;
    return DispatchResult(bytes: _buildEchoParams('done'));
  }

  @override
  Future<DispatchResult> dispatchWithContext(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
    DispatchContext? context,
  }) {
    final dispatchContext = context ?? DispatchContext.neverCanceled;
    lastContext = dispatchContext;
    dispatchContext.canceled.then((_) {
      if (!canceled.isCompleted) canceled.complete();
    }).ignore();
    return dispatch(
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
  }

  @override
  Future<void> dispose() async {}
}

Future<void> _waitForRelease(List<Uint8List> captured) async {
  for (var i = 0; i < 20; i++) {
    if (captured
        .map(parseRpcMessage)
        .any((m) => m.type == RpcMessageType.release)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TestFailure('no Release message captured');
}

List<RpcMessage> _releaseMessages(List<Uint8List> captured) =>
    captured
        .map(parseRpcMessage)
        .where((m) => m.type == RpcMessageType.release)
        .toList();

Future<void> _waitForReleaseCount(
  List<Uint8List> captured,
  int expectedCount,
) async {
  for (var i = 0; i < 20; i++) {
    if (_releaseMessages(captured).length >= expectedCount) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TestFailure('expected $expectedCount Release messages');
}

Future<RpcMessage> _waitForMessageType(
  List<Uint8List> captured,
  RpcMessageType type,
) async {
  for (var i = 0; i < 20; i++) {
    final messages = captured.map(parseRpcMessage).where((m) => m.type == type);
    if (messages.isNotEmpty) return messages.last;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TestFailure('no $type message captured');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('rpc_proto — RPC-001 promisedAnswer encoding', () {
    test('buildCallMessage with promisedAnswer target encodes disc=1', () {
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory()).setTextField(0, 'x');
      final params = mb.serialize();

      final bytes = buildCallMessage(
        questionId: 5,
        targetPromisedAnswerQid: 3,
        targetPtrIndex: 0,
        interfaceId: 0xABCD,
        methodId: 1,
        paramsBytes: params,
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.call);
      expect(msg.questionId, 5);
      expect(msg.targetIsPromisedAnswer, isTrue);
      expect(msg.targetPromisedAnswerQid, 3);
      expect(msg.targetPtrIndex, 0);
    });

    test('importedCap target still parses correctly', () {
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory());
      final params = mb.serialize();

      final bytes = buildCallMessage(
        questionId: 7,
        targetImportId: 42,
        interfaceId: 0x1234,
        methodId: 0,
        paramsBytes: params,
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.targetIsPromisedAnswer, isFalse);
      expect(msg.targetImportId, 42);
    });
  });

  group('TwoPartyRpcConnection — RPC-001 wire-level promise pipelining', () {
    test('two pipelined calls are sent before first Return arrives', () async {
      // Intercept all bytes from client to server.
      final clientToServer = StreamController<Uint8List>();
      final serverToClient = StreamController<Uint8List>();
      final captured = <Uint8List>[];

      final interceptSink =
          StreamController<Uint8List>()
            ..stream.listen((b) {
              captured.add(b);
              clientToServer.add(b);
            });

      final server = PipelineServer();
      TwoPartyRpcConnection.server(
        incoming: clientToServer.stream,
        outgoing: serverToClient.sink,
        bootstrap: server,
      );
      final client = TwoPartyRpcConnection.client(
        incoming: serverToClient.stream,
        outgoing: interceptSink.sink,
      );

      final bootstrapCap = client.bootstrap(EchoClientFactory());
      await bootstrapCap.echo('warmup'); // complete bootstrap

      // Call getPipeline (returns a cap) and immediately call echo on the
      // pipelined result — both should be sent without waiting for getPipeline
      // to complete.
      captured.clear();
      final call = bootstrapCap.cap.beginDispatch(
        _echoInterfaceId,
        _pipelineMethodId,
        _buildEchoParams(''),
      );
      final pipelinedCap = call.pipelineResult(0);

      // Dispatch a second call on the pipelined cap before the first returns.
      final secondCall = pipelinedCap.dispatch(
        _echoInterfaceId,
        _echoMethodId,
        _buildEchoParams('hi'),
      );

      // Await both to complete the exchange.
      await call.result;
      await secondCall;

      // Verify both Call messages were sent as a batch (before any Return).
      final calls =
          captured
              .map(parseRpcMessage)
              .where((m) => m.type == RpcMessageType.call)
              .toList();
      expect(calls.length, greaterThanOrEqualTo(2));

      // The second call must target promisedAnswer, not importedCap.
      final pipelinedCall = calls.firstWhere(
        (m) => m.targetIsPromisedAnswer,
        orElse:
            () =>
                throw TestFailure(
                  'no promisedAnswer-targeted call found in captured messages',
                ),
      );
      expect(pipelinedCall.targetPromisedAnswerQid, calls.first.questionId);
      expect(pipelinedCall.targetPtrIndex, 0);

      await client.close();
    });

    test(
      'pipelined call on ptr slot 1 (cap after non-cap slot) resolves correctly',
      () async {
        // This is the RPC-001 regression test.
        // The result struct has slot 0 = null (not a cap) and slot 1 = capability.
        // ptrIndex=1 must resolve to caps[0], not caps[1] (which would be OOB).
        final server = MixedResultServer();
        final (client, serverConn) = _makePipe(server);
        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        final call = bootstrapCap.cap.beginDispatch(
          _echoInterfaceId,
          _mixedMethodId,
          _buildEchoParams(''),
        );
        // Pipeline onto ptr slot 1 (not slot 0), where the capability lives.
        final pipelinedCap = call.pipelineResult(1);

        final secondResult = await pipelinedCap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('piped'),
        );
        expect(_parseEchoResult(secondResult.bytes), equals('echo: piped'));

        await client.close();
        await serverConn.close();
      },
    );

    test(
      'pipelined capability parameter is encoded as receiverAnswer',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final captured = <Uint8List>[];
        final completeParent = Completer<void>();

        final interceptSink =
            StreamController<Uint8List>()
              ..stream.listen((b) {
                captured.add(b);
                clientToServer.add(b);
              });

        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: ChildPipelineServer(completer: completeParent),
        );
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: interceptSink.sink,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        captured.clear();
        final parent = bootstrapCap.cap.beginDispatch(
          _echoInterfaceId,
          _pipelineMethodId,
          _buildEchoParams(''),
        );
        final pipelinedCap = parent.pipelineResult(0);
        final paramCall = bootstrapCap.cap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('param'),
          paramsCapabilities: [pipelinedCap],
        );

        final (parentCall, callWithCap) = await () async {
          for (var i = 0; i < 20; i++) {
            final calls =
                captured
                    .map(parseRpcMessage)
                    .where((m) => m.type == RpcMessageType.call)
                    .toList();
            final parentCalls =
                calls.where((m) => m.methodId == _pipelineMethodId).toList();
            final capCalls =
                calls.where((m) => m.capTableDescriptors.isNotEmpty).toList();
            if (parentCalls.isNotEmpty && capCalls.isNotEmpty) {
              return (parentCalls.single, capCalls.single);
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          throw TestFailure('no Call with capTable captured');
        }();

        expect(callWithCap.capTableDescriptors.single.disc, 4);
        expect(
          callWithCap.capTableDescriptors.single.questionId,
          parentCall.questionId,
        );
        expect(callWithCap.capTableDescriptors.single.ptrIndex, 0);

        completeParent.complete();
        await parent.result;
        await paramCall;
        await client.close();
        await interceptSink.close();
      },
    );

    test(
      'Capability.beginDispatch on non-RPC cap falls back to DeferredCapability',
      () async {
        final server = EchoServer();
        final call = server.beginDispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('test'),
        );
        // pipelineResult on a non-RPC cap returns a DeferredCapability.
        final piped = call.pipelineResult(0);
        expect(piped, isA<DeferredCapability>());
        // The result future still completes correctly.
        final result = await call.result;
        final text = _parseEchoResult(result.bytes);
        expect(text, 'echo: test');
      },
    );

    test(
      'disposing resolved pipelined capability releases imported cap',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final captured = <Uint8List>[];

        final interceptSink =
            StreamController<Uint8List>()
              ..stream.listen((b) {
                captured.add(b);
                clientToServer.add(b);
              });

        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: ChildPipelineServer(),
        );
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: interceptSink.sink,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        captured.clear();
        final call = bootstrapCap.cap.beginDispatch(
          _echoInterfaceId,
          _pipelineMethodId,
          _buildEchoParams(''),
        );
        final pipelinedCap = call.pipelineResult(0);
        await call.result;

        await pipelinedCap.dispose();
        await _waitForRelease(captured);

        final releases =
            captured
                .map(parseRpcMessage)
                .where((m) => m.type == RpcMessageType.release)
                .toList();
        expect(releases, hasLength(1));
        expect(releases.single.referenceCount, equals(1));

        await client.close();
        await interceptSink.close();
      },
    );

    test(
      'disposing pending pipelined capability releases after parent resolves',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final captured = <Uint8List>[];
        final completeParent = Completer<void>();

        final interceptSink =
            StreamController<Uint8List>()
              ..stream.listen((b) {
                captured.add(b);
                clientToServer.add(b);
              });

        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: ChildPipelineServer(completer: completeParent),
        );
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: interceptSink.sink,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        captured.clear();
        final call = bootstrapCap.cap.beginDispatch(
          _echoInterfaceId,
          _pipelineMethodId,
          _buildEchoParams(''),
        );
        final pipelinedCap = call.pipelineResult(0);

        await pipelinedCap.dispose();
        expect(
          captured
              .map(parseRpcMessage)
              .where((m) => m.type == RpcMessageType.release),
          isEmpty,
        );

        completeParent.complete();
        await call.result;
        await _waitForRelease(captured);

        final releases =
            captured
                .map(parseRpcMessage)
                .where((m) => m.type == RpcMessageType.release)
                .toList();
        expect(releases, hasLength(1));
        expect(releases.single.referenceCount, equals(1));

        await client.close();
        await interceptSink.close();
      },
    );

    test(
      'disposing pending pipelined capability waits for in-flight pipelined call',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final captured = <Uint8List>[];
        final completeParent = Completer<void>();
        final uncaught = <Object>[];

        final interceptSink =
            StreamController<Uint8List>()
              ..stream.listen((b) {
                captured.add(b);
                clientToServer.add(b);
              });

        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: ChildPipelineServer(completer: completeParent),
        );
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: interceptSink.sink,
        );

        final bodyDone = Completer<void>();
        runZonedGuarded(() {
          () async {
            try {
              final bootstrapCap = client.bootstrap(EchoClientFactory());
              await bootstrapCap.echo('warmup');

              captured.clear();
              final parent = bootstrapCap.cap.beginDispatch(
                _echoInterfaceId,
                _pipelineMethodId,
                _buildEchoParams(''),
              );
              final pipelinedCap = parent.pipelineResult(0);
              final pipelinedCall = pipelinedCap.dispatch(
                _echoInterfaceId,
                _echoMethodId,
                _buildEchoParams('piped'),
              );

              await pipelinedCap.dispose();
              completeParent.complete();

              await parent.result.timeout(const Duration(seconds: 2));
              final pipedResult = await pipelinedCall.timeout(
                const Duration(seconds: 2),
              );
              expect(
                _parseEchoResult(pipedResult.bytes),
                equals('echo: piped'),
              );
              await _waitForRelease(captured);
              bodyDone.complete();
            } catch (error, stackTrace) {
              bodyDone.completeError(error, stackTrace);
            }
          }();
        }, (error, _) => uncaught.add(error));

        await bodyDone.future;
        expect(uncaught, isEmpty);

        final releases = _releaseMessages(captured);
        expect(releases, hasLength(1));
        expect(releases.single.referenceCount, equals(1));

        await client.close();
        await interceptSink.close();
      },
    );

    test(
      'parent failure is preserved for resolved pipelined capability',
      () async {
        final server = PipelineServer();
        final (client, serverConn) = _makePipe(server);
        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        final call = bootstrapCap.cap.beginDispatch(
          _echoInterfaceId,
          999,
          _buildEchoParams(''),
        );
        final pipelinedCap = call.pipelineResult(0);

        await expectLater(call.result, throwsA(isA<RpcException>()));
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          pipelinedCap.dispatch(
            _echoInterfaceId,
            _echoMethodId,
            _buildEchoParams('piped'),
          ),
          throwsA(
            allOf(
              isA<RpcException>(),
              predicate<Object>(
                (e) =>
                    e.toString().contains('unknown method') &&
                    !e.toString().contains('null capability'),
              ),
            ),
          ),
        );

        await client.close();
        await serverConn.close();
      },
    );

    test('disposing one duplicate import keeps the other usable', () async {
      final clientToServer = StreamController<Uint8List>();
      final serverToClient = StreamController<Uint8List>();
      final captured = <Uint8List>[];

      final interceptSink =
          StreamController<Uint8List>()
            ..stream.listen((b) {
              captured.add(b);
              clientToServer.add(b);
            });

      TwoPartyRpcConnection.server(
        incoming: clientToServer.stream,
        outgoing: serverToClient.sink,
        bootstrap: DuplicateCapsServer(),
      );
      final client = TwoPartyRpcConnection.client(
        incoming: serverToClient.stream,
        outgoing: interceptSink.sink,
      );

      final bootstrapCap = client.bootstrap(EchoClientFactory());
      await bootstrapCap.echo('warmup');

      captured.clear();
      final call = bootstrapCap.cap.beginDispatch(
        _echoInterfaceId,
        _duplicateCapsMethodId,
        _buildEchoParams(''),
      );
      final result = await call.result;
      final capA = requireCapabilityFromResult(result, 0);
      final capB = requireCapabilityFromResult(result, 1);

      await capA.dispose();
      await _waitForReleaseCount(captured, 1);
      var releases = _releaseMessages(captured);
      expect(releases, hasLength(1));
      expect(releases.single.referenceCount, equals(1));

      final secondResult = await capB.dispatch(
        _echoInterfaceId,
        _echoMethodId,
        _buildEchoParams('still-live'),
      );
      expect(_parseEchoResult(secondResult.bytes), equals('echo: still-live'));

      await capB.dispose();
      await _waitForReleaseCount(captured, 2);
      releases = _releaseMessages(captured);
      expect(releases, hasLength(2));
      expect(releases.map((m) => m.referenceCount), everyElement(equals(1)));
      expect(
        releases.fold<int>(0, (sum, msg) => sum + msg.referenceCount),
        equals(2),
      );

      await capB.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(_releaseMessages(captured), hasLength(2));

      await client.close();
      await interceptSink.close();
    });

    test(
      'multi-segment result with capability pointer returns callable cap',
      () async {
        final server = LargeCapabilityPayloadServer();
        final (client, serverConn) = _makePipe(server);
        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        final result = await bootstrapCap.cap.dispatch(
          _echoInterfaceId,
          _largeCapResultMethodId,
          _buildEchoParams(''),
        );
        final root = MessageReader.deserialize(
          result.bytes,
        ).getRoot(_TwoPtrFactory());

        expect(_segmentCount(result.bytes), greaterThan(1));
        expect(root.getDataField(0), orderedEquals(_largeData(10000)));
        expect(root.getCapabilityField(1), equals(0));

        final returnedCap = requireCapabilityFromResult(result, 1);
        final reply = await returnedCap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('through returned cap'),
        );
        expect(
          _parseEchoResult(reply.bytes),
          equals('echo: through returned cap'),
        );

        await client.close();
        await serverConn.close();
      },
    );

    test(
      'multi-segment params with capability pointer deliver callable cap',
      () async {
        final server = LargeCapabilityPayloadServer();
        final (client, serverConn) = _makePipe(server);
        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        final localCap = EchoServer();
        final result = await bootstrapCap.cap.dispatch(
          _echoInterfaceId,
          _largeCapParamMethodId,
          _buildLargeDataAndCapResult(10000),
          paramsCapabilities: [localCap],
        );

        expect(_parseEchoResult(result.bytes), equals('ok'));
        expect(server.lastDataLength, equals(10000));
        expect(server.lastParamCapReply, equals('echo: from server'));

        await client.close();
        await serverConn.close();
      },
    );

    test('invalid result pointer is preserved for resolved pipeline', () async {
      final server = MixedResultServer();
      final (client, serverConn) = _makePipe(server);
      final bootstrapCap = client.bootstrap(EchoClientFactory());
      await bootstrapCap.echo('warmup');

      final call = bootstrapCap.cap.beginDispatch(
        _echoInterfaceId,
        _mixedMethodId,
        _buildEchoParams(''),
      );
      final pipelinedCap = call.pipelineResult(0);
      await call.result;
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        pipelinedCap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('piped'),
        ),
        throwsA(
          allOf(
            isA<RpcException>(),
            predicate<Object>(
              (e) =>
                  e.toString().contains('not a capability') &&
                  !e.toString().contains('null capability'),
            ),
          ),
        ),
      );

      await client.close();
      await serverConn.close();
    });

    test('negative result pointer index is rejected explicitly', () async {
      final server = DuplicateCapsServer();
      final (client, serverConn) = _makePipe(server);
      final bootstrapCap = client.bootstrap(EchoClientFactory());
      await bootstrapCap.echo('warmup');

      final result = await bootstrapCap.cap.dispatch(
        _echoInterfaceId,
        _duplicateCapsMethodId,
        _buildEchoParams(''),
      );

      expect(
        () => requireCapabilityFromResult(result, -1),
        throwsA(
          allOf(
            isA<RpcException>(),
            predicate<Object>(
              (e) => e.toString().contains('pointer slot -1 is out of range'),
            ),
          ),
        ),
      );

      await client.close();
      await serverConn.close();
    });

    test(
      'failed call send preparation cleans pending question state',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final outgoing = StreamController<Uint8List>();

        outgoing.stream.listen(clientToServer.add);
        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: PipelineServer(),
        );
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: outgoing.sink,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');
        expect(client.debugPendingQuestionCount, equals(0));
        expect(client.debugPendingQuestionSentCount, equals(0));

        await outgoing.close();
        final result = bootstrapCap.cap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('will-fail-before-send'),
        );

        await expectLater(result, throwsA(anything));
        expect(client.debugPendingQuestionCount, equals(0));
        expect(client.debugPendingQuestionSentCount, equals(0));

        await client.close();
      },
    );
  });

  group('TwoPartyRpcConnection — RPC-005/RPC-006 lifecycle', () {
    test(
      'bootstrap Return without a capability fails the bootstrap cap',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        clientToServer.stream.listen((_) {});

        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
        );
        final stub = client.bootstrap(EchoClientFactory());

        serverToClient.add(
          buildReturnResultsMessage(
            answerId: 0,
            resultsBytes: _buildEchoParams('no-cap'),
          ),
        );

        await expectLater(
          stub.echo('hello').timeout(const Duration(milliseconds: 100)),
          throwsA(
            allOf(
              isA<RpcException>(),
              predicate<Object>(
                (e) => e.toString().contains(
                  'bootstrap Return had no capability in cap table',
                ),
              ),
            ),
          ),
        );

        await serverToClient.close();
        await client.close();
      },
    );

    test(
      'Finish before Return suppresses the completed dispatch result',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final captured = <RpcMessage>[];
        serverToClient.stream.listen(
          (bytes) => captured.add(parseRpcMessage(bytes)),
        );

        final server = SlowEchoServer();
        final serverConn = TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: server,
        );

        clientToServer.add(
          buildCallMessage(
            questionId: 1,
            targetImportId: 0,
            interfaceId: _echoInterfaceId,
            methodId: _echoMethodId,
            paramsBytes: _buildEchoParams('slow'),
          ),
        );
        await server.started.future;

        clientToServer.add(buildFinishMessage(1));
        await server.canceled.future.timeout(const Duration(milliseconds: 100));
        expect(server.lastContext?.isCanceled, isTrue);
        server.complete.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          captured.where((m) => m.type == RpcMessageType.return_),
          isEmpty,
        );

        await clientToServer.close();
        await serverConn.done;
      },
    );

    test('connection close cancels an in-progress dispatch context', () async {
      final clientToServer = StreamController<Uint8List>();
      final serverToClient = StreamController<Uint8List>();
      serverToClient.stream.listen((_) {});

      final server = SlowEchoServer();
      final serverConn = TwoPartyRpcConnection.server(
        incoming: clientToServer.stream,
        outgoing: serverToClient.sink,
        bootstrap: server,
      );

      clientToServer.add(
        buildCallMessage(
          questionId: 1,
          targetImportId: 0,
          interfaceId: _echoInterfaceId,
          methodId: _echoMethodId,
          paramsBytes: _buildEchoParams('slow'),
        ),
      );
      await server.started.future;

      await clientToServer.close();
      await server.canceled.future.timeout(const Duration(milliseconds: 100));
      expect(server.lastContext?.isCanceled, isTrue);
      server.complete.complete();

      await serverConn.done;
    });
  });

  group('rpc_proto — message encoding/decoding', () {
    test('bootstrap round-trip', () {
      final bytes = buildBootstrapMessage(42);
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.bootstrap);
      expect(msg.questionId, 42);
    });

    test('call round-trip', () {
      // Build a valid Cap'n Proto message to use as params.
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory()).setTextField(0, 'hello');
      final params = mb.serialize();

      final bytes = buildCallMessage(
        questionId: 7,
        targetImportId: 3,
        interfaceId: 0xDEADBEEF,
        methodId: 5,
        paramsBytes: params,
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.call);
      expect(msg.questionId, 7);
      expect(msg.targetImportId, 3);
      expect(msg.interfaceId, 0xDEADBEEF);
      expect(msg.methodId, 5);
      // Verify the params round-trip correctly (semantic equality).
      final paramsMr = MessageReader.deserialize(msg.paramsBytes!);
      expect(paramsMr.getRoot(_TextParamFactory()).getTextField(0), 'hello');
    });

    test('call params round-trip multi-segment payload semantics', () {
      final params = _buildLargeDataParams(10000);

      final bytes = buildCallMessage(
        questionId: 8,
        targetImportId: 3,
        interfaceId: 0xDEADBEEF,
        methodId: 5,
        paramsBytes: params,
      );
      expect(_segmentCount(bytes), greaterThan(1));

      final msg = parseRpcMessage(bytes);
      final decoded = MessageReader.deserialize(
        msg.paramsBytes!,
      ).getRoot(_TextParamFactory());

      expect(_segmentCount(msg.paramsBytes!), greaterThan(1));
      expect(decoded.getDataField(0), orderedEquals(_largeData(10000)));
    });

    test('return results round-trip', () {
      // Build a valid Cap'n Proto message to use as results.
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory()).setTextField(0, 'world');
      final results = mb.serialize();

      final bytes = buildReturnResultsMessage(
        answerId: 99,
        resultsBytes: results,
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.return_);
      expect(msg.answerId, 99);
      expect(msg.isReturnResults, isTrue);
      // Verify the results round-trip correctly (semantic equality).
      final resultsMr = MessageReader.deserialize(msg.resultsBytes!);
      expect(resultsMr.getRoot(_TextParamFactory()).getTextField(0), 'world');
    });

    test('return results round-trip multi-segment payload semantics', () {
      final results = _buildLargeDataParams(10000);

      final bytes = buildReturnResultsMessage(
        answerId: 100,
        resultsBytes: results,
      );
      expect(_segmentCount(bytes), greaterThan(1));

      final msg = parseRpcMessage(bytes);
      final decoded = MessageReader.deserialize(
        msg.resultsBytes!,
      ).getRoot(_TextParamFactory());

      expect(_segmentCount(msg.resultsBytes!), greaterThan(1));
      expect(decoded.getDataField(0), orderedEquals(_largeData(10000)));
    });

    test(
      'return results preserve capability pointers with multi-segment payload',
      () {
        final results = _buildLargeDataAndCapResult(10000);

        final bytes = buildReturnResultsWithCapsMessage(
          answerId: 101,
          resultsBytes: results,
          exportIds: const [123],
        );
        expect(_segmentCount(bytes), greaterThan(1));

        final msg = parseRpcMessage(bytes);
        final decoded = MessageReader.deserialize(
          msg.resultsBytes!,
        ).getRoot(_TwoPtrFactory());

        expect(_segmentCount(msg.resultsBytes!), greaterThan(1));
        expect(decoded.getDataField(0), orderedEquals(_largeData(10000)));
        expect(decoded.getCapabilityField(1), equals(0));
        expect(msg.capTableExportIds, equals([123]));
      },
    );

    test('return exception round-trip', () {
      final bytes = buildReturnExceptionMessage(
        answerId: 5,
        reason: 'something broke',
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.return_);
      expect(msg.answerId, 5);
      expect(msg.isReturnException, isTrue);
      expect(msg.exceptionReason, 'something broke');
    });

    test('bootstrap return round-trip (capTable)', () {
      final bytes = buildBootstrapReturnMessage(answerId: 1, exportId: 42);
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.return_);
      expect(msg.answerId, 1);
      expect(msg.isReturnResults, isTrue);
      expect(msg.capTableExportIds, [42]);
      expect(msg.capTableEntries, const [(1, 42)]);
    });

    test('resolve cap round-trip', () {
      final bytes = buildResolveCapMessage(
        promiseId: 11,
        capDisc: 2,
        capId: 42,
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.resolve);
      expect(msg.promiseId, 11);
      expect(msg.isResolveCap, isTrue);
      expect(msg.resolveCap, const (2, 42));
    });

    test('resolve exception round-trip', () {
      final bytes = buildResolveExceptionMessage(
        promiseId: 11,
        reason: 'promise failed',
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.resolve);
      expect(msg.promiseId, 11);
      expect(msg.isResolveException, isTrue);
      expect(msg.exceptionReason, 'promise failed');
    });

    test('disembargo senderLoopback round-trip', () {
      final bytes = buildDisembargoMessage(
        targetPromisedAnswerQid: 7,
        targetPtrIndex: 1,
        contextDisc: 0,
        contextId: 123,
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.disembargo);
      expect(msg.disembargoContextDisc, 0);
      expect(msg.disembargoContextId, 123);
      expect(msg.disembargoTargetIsPromisedAnswer, isTrue);
      expect(msg.disembargoTargetPromisedAnswerQid, 7);
      expect(msg.disembargoTargetPtrIndex, 1);
    });

    test('finish round-trip', () {
      final bytes = buildFinishMessage(3);
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.finish);
      expect(msg.questionId, 3);
      expect(msg.releaseResultCaps, isTrue);
    });

    test('release round-trip', () {
      final bytes = buildReleaseMessage(7, 2);
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.release);
      expect(msg.releaseId, 7);
      expect(msg.referenceCount, 2);
    });

    test('abort round-trip', () {
      final bytes = buildAbortMessage('fatal error');
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.abort);
      expect(msg.exceptionReason, 'fatal error');
    });
  });

  group('rpc_proto — RPC-003 receiverHosted encoding', () {
    test('buildCallMessage with receiverHosted entry encodes disc=3', () {
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory()).setTextField(0, 'x');
      final params = mb.serialize();

      final bytes = buildCallMessage(
        questionId: 1,
        targetImportId: 0,
        interfaceId: 0xABCD,
        methodId: 0,
        paramsBytes: params,
        capTableEntries: const [(3, 42)], // receiverHosted, importId=42
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.paramsCapTable, hasLength(1));
      expect(msg.paramsCapTable[0].$1, equals(3)); // disc=3: receiverHosted
      expect(msg.paramsCapTable[0].$2, equals(42));
    });

    test('buildCallMessage with senderHosted entry encodes disc=1', () {
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory());
      final params = mb.serialize();

      final bytes = buildCallMessage(
        questionId: 1,
        targetImportId: 0,
        interfaceId: 0xABCD,
        methodId: 0,
        paramsBytes: params,
        capTableEntries: const [(1, 7)], // senderHosted, exportId=7
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.paramsCapTable[0].$1, equals(1));
      expect(msg.paramsCapTable[0].$2, equals(7));
    });

    test('buildCallMessage with receiverAnswer entry encodes disc=4', () {
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory());
      final params = mb.serialize();

      final bytes = buildCallMessage(
        questionId: 1,
        targetImportId: 0,
        interfaceId: 0xABCD,
        methodId: 0,
        paramsBytes: params,
        capTableDescriptors: const [RpcCapDescriptor.receiverAnswer(9, 2)],
      );
      final msg = parseRpcMessage(bytes);
      expect(msg.capTableDescriptors, hasLength(1));
      expect(msg.capTableDescriptors[0].disc, equals(4));
      expect(msg.capTableDescriptors[0].questionId, equals(9));
      expect(msg.capTableDescriptors[0].ptrIndex, equals(2));
    });
  });

  group('rpc_proto — RPC-007 Unimplemented encoding', () {
    test('buildUnimplementedMessage has disc=0 (unimplemented)', () {
      final original = buildAbortMessage('test');
      final unimpl = buildUnimplementedMessage(original);
      final msg = parseRpcMessage(unimpl);
      expect(msg.type, equals(RpcMessageType.unimplemented));
    });

    test('unknown disc value parses as RpcMessageType.other', () {
      // Start from a known message and overwrite the disc field with an
      // unknown value (99).  Message layout in the framed bytes:
      //   [0..7]  framing header (8 bytes, 1 segment)
      //   [8..15] segment word 0: root struct pointer
      //   [16..23] segment word 1: Message data section (bytes 0-1 = disc)
      final releaseBytes = buildReleaseMessage(1, 1);
      final mangled = Uint8List.fromList(releaseBytes);
      mangled[16] = 99; // disc lo byte
      mangled[17] = 0; // disc hi byte
      expect(parseRpcMessage(mangled).type, equals(RpcMessageType.other));
    });
  });

  group(
    'TwoPartyRpcConnection — RPC-003 receiverHosted (imported cap returned to same peer)',
    () {
      test(
        'capability received from server and sent back arrives as server-side object',
        () async {
          final server = CapReceivingServer();
          final (client, serverConn) = _makePipe(server);

          // Bootstrap: returns the server object itself.
          final bootstrapCap = client.bootstrap(EchoClientFactory());

          // Warm up so the bootstrap exchange completes.
          await bootstrapCap.echo('warmup');

          // Call the server, passing the bootstrap capability back as a param.
          // With RPC-003 fixed, this should be sent as receiverHosted so the server
          // receives its own capability object — not a proxy.
          await bootstrapCap.cap.dispatch(
            _echoInterfaceId,
            _echoMethodId,
            _buildEchoParams('test'),
            paramsCapabilities: [bootstrapCap.cap],
          );

          // The server should have received its own capability (identity check).
          expect(server.lastParams, hasLength(1));
          expect(server.lastParams[0], same(server));

          await client.close();
          await serverConn.close();
        },
      );

      test(
        'capTable wire encoding uses disc=3 (receiverHosted) for imported cap',
        () async {
          // Intercept the bytes going from client to server.
          final clientToServer = StreamController<Uint8List>();
          final serverToClient = StreamController<Uint8List>();
          final captured = <Uint8List>[];

          final interceptSink =
              StreamController<Uint8List>()
                ..stream.listen((b) {
                  captured.add(b);
                  clientToServer.add(b);
                });

          final client = TwoPartyRpcConnection.client(
            incoming: serverToClient.stream,
            outgoing: interceptSink.sink,
          );
          TwoPartyRpcConnection.server(
            incoming: clientToServer.stream,
            outgoing: serverToClient.sink,
            bootstrap: EchoServer(),
          );

          final stub = client.bootstrap(EchoClientFactory());
          await stub.echo('warmup'); // ensure bootstrap is resolved

          // Call with the bootstrap cap itself as a capability param.
          await stub.cap.dispatch(
            _echoInterfaceId,
            _echoMethodId,
            _buildEchoParams(''),
            paramsCapabilities: [stub.cap],
          );

          // Find the Call message that has a non-empty capTable.
          final callWithCap =
              captured
                  .map(parseRpcMessage)
                  .where(
                    (m) =>
                        m.type == RpcMessageType.call &&
                        m.paramsCapTable.isNotEmpty,
                  )
                  .toList();

          expect(callWithCap, hasLength(1));
          // disc=3 means receiverHosted — the peer's own export, no proxy.
          expect(callWithCap.first.paramsCapTable.first.$1, equals(3));

          await client.close();
          await interceptSink.close();
        },
      );
    },
  );

  group('TwoPartyRpcConnection — RPC-007 Unimplemented for unknown messages', () {
    test(
      'server sends Unimplemented when it receives a message with unknown disc',
      () async {
        final serverInput = StreamController<Uint8List>();
        final serverOutput = StreamController<Uint8List>();
        final serverReceived = <RpcMessage>[];

        serverOutput.stream.listen(
          (bytes) => serverReceived.add(parseRpcMessage(bytes)),
        );

        TwoPartyRpcConnection.server(
          incoming: serverInput.stream,
          outgoing: serverOutput.sink,
          bootstrap: EchoServer(),
        );

        // Build a message with an unknown disc (99) by mangling a Release message.
        final releaseBytes = buildReleaseMessage(1, 1);
        final mangled = Uint8List.fromList(releaseBytes);
        mangled[16] = 99; // overwrite disc lo byte
        mangled[17] = 0;

        serverInput.add(mangled);
        await Future<void>.delayed(Duration.zero); // let the event loop run

        expect(
          serverReceived.any((m) => m.type == RpcMessageType.unimplemented),
          isTrue,
          reason:
              'server should reply with Unimplemented for unknown message disc',
        );

        await serverInput.close();
      },
    );
  });

  group('TwoPartyRpcConnection — RPC Level 1 Resolve / Disembargo', () {
    test(
      'incoming Resolve(cap) is handled and releases unused descriptor',
      () async {
        final input = StreamController<Uint8List>();
        final output = StreamController<Uint8List>();
        final received = <RpcMessage>[];
        output.stream.listen((bytes) => received.add(parseRpcMessage(bytes)));

        final conn = TwoPartyRpcConnection.server(
          incoming: input.stream,
          outgoing: output.sink,
          bootstrap: EchoServer(),
        );

        input.add(buildResolveCapMessage(promiseId: 9, capDisc: 1, capId: 42));
        await Future<void>.delayed(Duration.zero);

        expect(
          received.where((m) => m.type == RpcMessageType.unimplemented),
          isEmpty,
        );
        final releases =
            received.where((m) => m.type == RpcMessageType.release).toList();
        expect(releases, hasLength(1));
        expect(releases.single.releaseId, 42);
        expect(releases.single.referenceCount, 1);

        await input.close();
        await conn.done;
      },
    );

    test(
      'incoming Resolve(exception) is handled without Unimplemented',
      () async {
        final input = StreamController<Uint8List>();
        final output = StreamController<Uint8List>();
        final received = <RpcMessage>[];
        output.stream.listen((bytes) => received.add(parseRpcMessage(bytes)));

        final conn = TwoPartyRpcConnection.server(
          incoming: input.stream,
          outgoing: output.sink,
          bootstrap: EchoServer(),
        );

        input.add(
          buildResolveExceptionMessage(promiseId: 9, reason: 'promise failed'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          received.where((m) => m.type == RpcMessageType.unimplemented),
          isEmpty,
        );

        await input.close();
        await conn.done;
      },
    );

    test(
      'incoming Disembargo(senderLoopback) is echoed as receiverLoopback',
      () async {
        final input = StreamController<Uint8List>();
        final output = StreamController<Uint8List>();
        final received = <RpcMessage>[];
        output.stream.listen((bytes) => received.add(parseRpcMessage(bytes)));

        final conn = TwoPartyRpcConnection.server(
          incoming: input.stream,
          outgoing: output.sink,
          bootstrap: EchoServer(),
        );

        input.add(
          buildDisembargoMessage(
            targetImportId: 0,
            contextDisc: 0,
            contextId: 123,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final disembargo =
            received.where((m) => m.type == RpcMessageType.disembargo).toList();
        expect(disembargo, hasLength(1));
        expect(disembargo.single.disembargoContextDisc, 1);
        expect(disembargo.single.disembargoContextId, 123);
        expect(disembargo.single.disembargoTargetImportId, 0);

        await input.close();
        await conn.done;
      },
    );

    test(
      'promise resolving to local capability waits for receiverLoopback',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final captured = <Uint8List>[];

        final interceptSink =
            StreamController<Uint8List>()
              ..stream.listen((b) {
                captured.add(b);
                clientToServer.add(b);
              });

        clientToServer.stream.listen((_) {});
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: interceptSink.sink,
        );
        final stub = client.bootstrap(EchoClientFactory());

        // Resolve bootstrap to a senderPromise import.
        serverToClient.add(
          buildReturnResultsWithCapDescriptorsMessage(
            answerId: 0,
            resultsBytes: _buildEchoParams(''),
            descriptors: const [RpcCapDescriptor.senderPromise(10)],
          ),
        );
        await Future<void>.delayed(Duration.zero);

        captured.clear();
        final local = EchoServer();
        final firstCall = stub.cap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('before'),
          paramsCapabilities: [local],
        );
        firstCall.ignore();

        final call = await _waitForMessageType(captured, RpcMessageType.call);
        expect(call.targetImportId, 10);
        expect(call.paramsCapTable, hasLength(1));
        expect(call.paramsCapTable.single.$1, 1); // local cap exported

        captured.clear();
        serverToClient.add(
          buildResolveCapMessage(promiseId: 10, capDisc: 3, capId: 1),
        );
        final disembargo = await _waitForMessageType(
          captured,
          RpcMessageType.disembargo,
        );
        expect(disembargo.disembargoContextDisc, 0);
        expect(disembargo.disembargoTargetImportId, 10);

        final afterCall = stub.echo('after');
        var afterCompleted = false;
        afterCall.then((_) => afterCompleted = true).ignore();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(afterCompleted, isFalse);

        serverToClient.add(
          buildDisembargoMessage(
            targetImportId: 10,
            contextDisc: 1,
            contextId: disembargo.disembargoContextId,
          ),
        );
        expect(await afterCall, 'echo: after');

        await client.close();
        await interceptSink.close();
      },
    );
  });

  group('TwoPartyRpcConnection — in-memory', () {
    test('bootstrap returns a capability', () async {
      final (client, _) = _makePipe(EchoServer());
      final stub = client.bootstrap(EchoClientFactory());
      expect(stub, isA<EchoClient>());
      await client.close();
    });

    test('echo call succeeds', () async {
      final (client, server) = _makePipe(EchoServer());
      final stub = client.bootstrap(EchoClientFactory());
      final reply = await stub.echo('hello');
      expect(reply, 'echo: hello');
      await client.close();
      await server.close();
    });

    test('multiple calls on the same connection', () async {
      final (client, server) = _makePipe(EchoServer());
      final stub = client.bootstrap(EchoClientFactory());
      final replies = await Future.wait([
        stub.echo('a'),
        stub.echo('b'),
        stub.echo('c'),
      ]);
      expect(replies, ['echo: a', 'echo: b', 'echo: c']);
      await client.close();
      await server.close();
    });

    test('server dispatches unknown method as exception', () async {
      final (client, server) = _makePipe(EchoServer());
      final stub = client.bootstrap(EchoClientFactory());
      // Warm up so bootstrap completes, then dispatch with wrong methodId.
      await stub.echo('warmup');
      final wrongCall = stub.cap.dispatch(
        _echoInterfaceId,
        99,
        _buildEchoParams('x'),
      );
      await expectLater(wrongCall, throwsA(isA<RpcException>()));
      await client.close();
      await server.close();
    });

    test('call on closed connection is rejected', () async {
      final (client, server) = _makePipe(EchoServer());
      final stub = client.bootstrap(EchoClientFactory());
      await stub.echo('warmup');
      await client.close();
      await expectLater(stub.echo('after close'), throwsA(isA<RpcException>()));
      await server.close();
    });
  });
}
