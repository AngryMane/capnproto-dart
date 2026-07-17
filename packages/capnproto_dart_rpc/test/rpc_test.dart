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
const int _listCapsResultMethodId = 6; // result has List(Interface) in ptr[0]
const int _listCapsParamMethodId = 7; // params have List(Interface) in ptr[0]

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

// Throws synchronously inside dispatchWithContext (before returning a Future).
class _SyncThrowingCapability extends Capability {
  @override
  Future<DispatchResult> dispatchWithContext(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
    DispatchContext? context,
  }) {
    throw StateError('deliberate synchronous throw');
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => Future.error(UnsupportedError('not reached'));

  @override
  Future<void> dispose() async {}
}

// Throws synchronously only on the first call; subsequent calls echo normally.
class _FirstCallSyncThrowCapability extends Capability {
  int _callCount = 0;

  @override
  Future<DispatchResult> dispatchWithContext(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
    DispatchContext? context,
  }) {
    _callCount++;
    if (_callCount == 1) throw StateError('deliberate synchronous throw');
    return dispatch(
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    final mr = MessageReader.deserialize(params);
    final message = mr.getRoot(_TextParamFactory()).getTextField(0) ?? '';
    return DispatchResult(bytes: _buildEchoParams('echo: $message'));
  }

  @override
  Future<void> dispose() async {}
}

class ThrowingDisposeCapability extends Capability {
  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => Future.error(UnsupportedError('not used'));

  @override
  Future<void> dispose() async {
    await Future<void>.delayed(Duration.zero);
    throw StateError('dispose failed');
  }
}

// Unlike ThrowingDisposeCapability, this one is deliberately NOT `async`: it
// throws before ever returning a Future, exercising the case where
// Capability.dispose() (typed Future<void>) is implemented by something
// that isn't actually asynchronous under the hood.
class SyncThrowingDisposeCapability extends Capability {
  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => Future.error(UnsupportedError('not used'));

  @override
  Future<void> dispose() {
    throw StateError('sync dispose failed');
  }
}

class CountingCapability extends EchoServer {
  int disposeCount = 0;
  int dispatchCount = 0;

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    dispatchCount++;
    return super.dispatch(
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
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

// Returns the same capability instance (passed in at construction) as a
// result capability on every _pipelineMethodId call — unlike
// ChildPipelineServer, which allocates its own child. Used to test that
// exporting the *same* capability across multiple Returns reuses one export
// entry instead of allocating a new one per call.
class FixedCapServer extends Capability {
  final Capability target;
  FixedCapServer(this.target);

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (methodId == _pipelineMethodId) {
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory()).setCapabilityField(0, 0);
      return DispatchResult(bytes: mb.serialize(), caps: [target]);
    }
    if (methodId == _echoMethodId) {
      return DispatchResult(bytes: _buildEchoParams('ok'));
    }
    throw RpcException('unknown method: $methodId');
  }

  @override
  Future<void> dispose() async {}
}

class PromisedReturnServer extends Capability {
  final Completer<Capability> completer = Completer<Capability>();
  late final DeferredCapability promised = DeferredCapability(completer.future);

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (methodId == _pipelineMethodId) {
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory()).setCapabilityField(0, 0);
      return DispatchResult(bytes: mb.serialize(), caps: [promised]);
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
// ListCapsServer — tests List(Interface) over RPC
//   method 6 (_listCapsResultMethodId): returns struct with List(Interface) in ptr[0]
//   method 7 (_listCapsParamMethodId):  reads List(Interface) from params, calls each
// ---------------------------------------------------------------------------

class ListCapsServer extends Capability {
  final EchoServer child0 = EchoServer();
  final EchoServer child1 = EchoServer();

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (methodId == _echoMethodId) {
      return DispatchResult(bytes: _buildEchoParams('ok'));
    }
    if (methodId == _listCapsResultMethodId) {
      final mb = MessageBuilder();
      final list = mb.initRoot(_TextParamFactory()).initCapabilityListField(0, 2);
      list[0] = 0;
      list[1] = 1;
      return DispatchResult(bytes: mb.serialize(), caps: [child0, child1]);
    }
    if (methodId == _listCapsParamMethodId) {
      final root = MessageReader.deserialize(params).getRoot(_TextParamFactory());
      final rawList = root.getCapabilityListField(0);
      if (rawList == null || rawList.length < 2) {
        throw const RpcException('expected List(Interface) with 2 caps in ptr[0]');
      }
      final cap0 = paramsCapabilities[rawList[0]];
      final cap1 = paramsCapabilities[rawList[1]];
      final r0 = await cap0.dispatch(_echoInterfaceId, _echoMethodId, _buildEchoParams('a'));
      final r1 = await cap1.dispatch(_echoInterfaceId, _echoMethodId, _buildEchoParams('b'));
      final reply = '${_parseEchoResult(r0.bytes)}|${_parseEchoResult(r1.bytes)}';
      return DispatchResult(bytes: _buildEchoParams(reply));
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

// A server whose dispatch stays pending until complete() is called, and
// then resolves with a result carrying [resultCaps] (which may repeat the
// same instance, to test dedup) — used to test that a dispatch result
// discarded before it could be sent as a Return (connection closed, or a
// Finish canceled the answer first) still gets its capabilities disposed
// instead of leaked.
class SlowCapResultServer extends Capability {
  final Completer<void> started = Completer<void>();
  final Completer<void> complete = Completer<void>();
  final List<Capability> resultCaps;

  SlowCapResultServer(this.resultCaps);

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (!started.isCompleted) started.complete();
    await complete.future;
    final mb = MessageBuilder();
    final root = mb.initRoot(_TwoPtrFactory());
    for (var i = 0; i < resultCaps.length; i++) {
      root.setCapabilityField(i, i);
    }
    return DispatchResult(bytes: mb.serialize(), caps: resultCaps);
  }

  @override
  Future<void> dispose() async {}
}

// A server whose calls each stay pending until individually released via
// completeNext(), in call order — used to control exactly when each
// streaming call's "ack" (Return) lands, to test FlowController windowing
// deterministically.
class QueuedSlowServer extends Capability {
  final List<Completer<DispatchResult>> _pending = [];
  int dispatchCount = 0;

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    dispatchCount++;
    final c = Completer<DispatchResult>();
    _pending.add(c);
    return c.future;
  }

  /// Completes the oldest still-pending call successfully, allowing its
  /// Return to be sent.
  void completeNext() {
    if (_pending.isNotEmpty) {
      _pending.removeAt(0).complete(DispatchResult.empty);
    }
  }

  /// Fails the oldest still-pending call, causing a Return-exception to be
  /// sent for it.
  void failNext(Object error) {
    if (_pending.isNotEmpty) _pending.removeAt(0).completeError(error);
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

    test('DeferredCapability is locally failed after dispose', () async {
      final completer = Completer<Capability>();
      final deferred = DeferredCapability(completer.future);
      final local = CountingCapability();

      final disposeFuture = deferred.dispose();
      completer.complete(local);
      await disposeFuture;
      await deferred.dispose();

      expect(local.disposeCount, equals(1));

      await expectLater(
        deferred.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('after-dispose'),
        ),
        throwsA(
          allOf(
            isA<RpcException>(),
            predicate<Object>(
              (e) => e.toString().contains('capability is disposed'),
            ),
          ),
        ),
      );
      expect(local.dispatchCount, equals(0));

      final call = deferred.beginDispatch(
        _echoInterfaceId,
        _echoMethodId,
        _buildEchoParams('after-dispose'),
      );
      await expectLater(call.result, throwsA(isA<RpcException>()));
      expect(local.dispatchCount, equals(0));
    });

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
      'disposed imported capability fails locally without sending Call',
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
          bootstrap: PipelineServer(),
        );
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: interceptSink.sink,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        final call = bootstrapCap.cap.beginDispatch(
          _echoInterfaceId,
          _pipelineMethodId,
          _buildEchoParams(''),
        );
        final pipelinedCap = call.pipelineResult(0);
        await call.result;

        captured.clear();
        await pipelinedCap.dispose();
        await _waitForRelease(captured);

        captured.clear();
        await expectLater(
          pipelinedCap.dispatch(
            _echoInterfaceId,
            _echoMethodId,
            _buildEchoParams('after-dispose'),
          ),
          throwsA(
            allOf(
              isA<RpcException>(),
              predicate<Object>(
                (e) => e.toString().contains('capability is disposed'),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          captured
              .map(parseRpcMessage)
              .where((m) => m.type == RpcMessageType.call),
          isEmpty,
        );

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
      'Release ignores async exported capability dispose failures',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final captured = <Uint8List>[];
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
          bootstrap: EchoServer(),
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
              await bootstrapCap.cap.dispatch(
                _echoInterfaceId,
                _echoMethodId,
                _buildEchoParams('with-cap'),
                paramsCapabilities: [ThrowingDisposeCapability()],
              );

              final callWithCap =
                  captured
                      .map(parseRpcMessage)
                      .where(
                        (m) =>
                            m.type == RpcMessageType.call &&
                            m.capTableDescriptors.isNotEmpty,
                      )
                      .single;
              final exportId = callWithCap.capTableDescriptors.single.id;

              serverToClient.add(buildReleaseMessage(exportId, 1));
              await Future<void>.delayed(const Duration(milliseconds: 20));
              bodyDone.complete();
            } catch (error, stackTrace) {
              bodyDone.completeError(error, stackTrace);
            }
          }();
        }, (error, _) => uncaught.add(error));

        await bodyDone.future;
        expect(uncaught, isEmpty);

        await client.close();
        await interceptSink.close();
      },
    );

    test(
      'onDisposeError observes an exported capability dispose failure '
      'instead of it being silently swallowed',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final captured = <Uint8List>[];
        final uncaught = <Object>[];
        final observedErrors = <Object>[];

        final interceptSink =
            StreamController<Uint8List>()
              ..stream.listen((b) {
                captured.add(b);
                clientToServer.add(b);
              });

        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: EchoServer(),
        );
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: interceptSink.sink,
          onDisposeError: (error, stackTrace) => observedErrors.add(error),
        );

        final bodyDone = Completer<void>();
        runZonedGuarded(() {
          () async {
            try {
              final bootstrapCap = client.bootstrap(EchoClientFactory());
              await bootstrapCap.echo('warmup');

              captured.clear();
              await bootstrapCap.cap.dispatch(
                _echoInterfaceId,
                _echoMethodId,
                _buildEchoParams('with-cap'),
                paramsCapabilities: [ThrowingDisposeCapability()],
              );

              final callWithCap =
                  captured
                      .map(parseRpcMessage)
                      .where(
                        (m) =>
                            m.type == RpcMessageType.call &&
                            m.capTableDescriptors.isNotEmpty,
                      )
                      .single;
              final exportId = callWithCap.capTableDescriptors.single.id;

              serverToClient.add(buildReleaseMessage(exportId, 1));
              await Future<void>.delayed(const Duration(milliseconds: 20));
              bodyDone.complete();
            } catch (error, stackTrace) {
              bodyDone.completeError(error, stackTrace);
            }
          }();
        }, (error, _) => uncaught.add(error));

        await bodyDone.future;
        // The dispose failure must reach onDisposeError...
        expect(observedErrors, hasLength(1));
        expect(observedErrors.single, isA<StateError>());
        // ...instead of leaking as an unhandled zone error.
        expect(uncaught, isEmpty);

        await client.close();
        await interceptSink.close();
      },
    );

    test(
      'a capability whose dispose() throws synchronously does not abort '
      "teardown's export-disposal loop — later capabilities are still "
      'disposed and close()/done still complete normally',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();

        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: EchoServer(),
        );

        final observedErrors = <Object>[];
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
          onDisposeError: (error, stackTrace) => observedErrors.add(error),
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        // Exporting a capability as a call *parameter* makes the sending
        // side (the client, here) the one that hosts/exports it — the same
        // mechanism the pre-existing Release-triggered dispose-failure
        // tests above use, just reaching _exports via teardown instead of
        // an explicit Release message.
        final syncFailingCap = SyncThrowingDisposeCapability();
        final okCap = CountingCapability();
        await bootstrapCap.cap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('a'),
          paramsCapabilities: [syncFailingCap],
        );
        await bootstrapCap.cap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('b'),
          paramsCapabilities: [okCap],
        );
        expect(client.debugExportCount, equals(2));

        // If the synchronous throw from syncFailingCap.dispose() escaped
        // _disposeIgnoringErrors unguarded, this would either hang (the
        // export loop/teardown never finishing) or reject with a
        // StateError instead of completing normally.
        await client.close().timeout(const Duration(milliseconds: 200));
        await client.done.timeout(const Duration(milliseconds: 200));

        expect(client.debugExportCount, equals(0));
        expect(okCap.disposeCount, equals(1));
        expect(observedErrors, hasLength(1));
        expect(observedErrors.single, isA<StateError>());
      },
    );

    test(
      'a throwing onDisposeError callback does not break dispose-error '
      'reporting for other capabilities, nor teardown completion',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();

        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: EchoServer(),
        );

        final uncaught = <Object>[];
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
          onDisposeError: (error, stackTrace) =>
              throw StateError('onDisposeError callback exploded'),
        );
        final okCap = CountingCapability();

        final bodyDone = Completer<void>();
        runZonedGuarded(() {
          () async {
            try {
              final bootstrapCap = client.bootstrap(EchoClientFactory());
              await bootstrapCap.echo('warmup');

              final firstFailingCap = ThrowingDisposeCapability();
              final secondFailingCap = ThrowingDisposeCapability();
              await bootstrapCap.cap.dispatch(
                _echoInterfaceId,
                _echoMethodId,
                _buildEchoParams('a'),
                paramsCapabilities: [firstFailingCap],
              );
              await bootstrapCap.cap.dispatch(
                _echoInterfaceId,
                _echoMethodId,
                _buildEchoParams('b'),
                paramsCapabilities: [secondFailingCap],
              );
              await bootstrapCap.cap.dispatch(
                _echoInterfaceId,
                _echoMethodId,
                _buildEchoParams('c'),
                paramsCapabilities: [okCap],
              );

              await client.close().timeout(const Duration(milliseconds: 200));
              await client.done.timeout(const Duration(milliseconds: 200));
              bodyDone.complete();
            } catch (error, stackTrace) {
              bodyDone.completeError(error, stackTrace);
            }
          }();
        }, (error, _) => uncaught.add(error));

        await bodyDone.future;

        expect(okCap.disposeCount, equals(1));
        expect(uncaught, isEmpty);
      },
    );

    test(
      'Release with referenceCount exceeding the outstanding remote '
      'refcount tears the connection down as a protocol violation',
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
          bootstrap: EchoServer(),
        );
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: interceptSink.sink,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        captured.clear();
        // Exports a capability with exactly one outstanding remote reference.
        await bootstrapCap.cap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('with-cap'),
          paramsCapabilities: [EchoServer()],
        );

        final callWithCap =
            captured
                .map(parseRpcMessage)
                .where(
                  (m) =>
                      m.type == RpcMessageType.call &&
                      m.capTableDescriptors.isNotEmpty,
                )
                .single;
        final exportId = callWithCap.capTableDescriptors.single.id;

        // Peer claims to release 2 references when only 1 was ever granted.
        serverToClient.add(buildReleaseMessage(exportId, 2));

        await expectLater(
          client.done,
          throwsA(
            predicate<Object>(
              (e) => e.toString().contains('protocol violation'),
            ),
          ),
        );

        // Teardown must actually happen, not just report on `done`.
        await expectLater(
          bootstrapCap.echo('after-violation'),
          throwsA(anything),
        );

        await interceptSink.close();
      },
    );

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
        // Finish-triggered suppression must leave no answer/cancellation
        // state behind, same as teardown-triggered suppression.
        expect(serverConn.debugAnswerCount, equals(0));
        expect(serverConn.debugCancellationCount, equals(0));

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

      // Teardown must have cleared the cancellation/answer tables even
      // though the dispatch itself only completes afterwards.
      expect(serverConn.debugCancellationCount, equals(0));
      expect(serverConn.debugAnswerCount, equals(0));
    });

    test(
      'a result capability is disposed exactly once when the connection '
      'closes before the dispatch that produced it resolves',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        serverToClient.stream.listen((_) {});

        final resultCap = CountingCapability();
        final server = SlowCapResultServer([resultCap]);
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
            methodId: _pipelineMethodId,
            paramsBytes: _buildEchoParams(''),
          ),
        );
        await server.started.future;

        await clientToServer.close();
        await serverConn.done;

        // Teardown finished before the dispatch itself resolved; the result
        // capability only becomes reachable once it does.
        expect(resultCap.disposeCount, equals(0));
        server.complete.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(resultCap.disposeCount, equals(1));
      },
    );

    test(
      'a result capability is disposed instead of leaked when the answer '
      'was already canceled by a Finish that arrived before dispatch '
      'resolved',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final captured = <RpcMessage>[];
        serverToClient.stream.listen(
          (bytes) => captured.add(parseRpcMessage(bytes)),
        );

        final resultCap = CountingCapability();
        final server = SlowCapResultServer([resultCap]);
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
            methodId: _pipelineMethodId,
            paramsBytes: _buildEchoParams(''),
          ),
        );
        await server.started.future;

        clientToServer.add(buildFinishMessage(1));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // The dispatch ignores cancellation and succeeds anyway; its result
        // capability was never going to be sent (Finish already suppressed
        // this answer), so it must be disposed instead of dropped.
        server.complete.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          captured.where((m) => m.type == RpcMessageType.return_),
          isEmpty,
        );
        expect(resultCap.disposeCount, equals(1));

        await clientToServer.close();
        await serverConn.done;
      },
    );

    test(
      'the same capability instance appearing twice in a discarded result '
      'is disposed once, not twice',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        serverToClient.stream.listen((_) {});

        final resultCap = CountingCapability();
        final server = SlowCapResultServer([resultCap, resultCap]);
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
            methodId: _pipelineMethodId,
            paramsBytes: _buildEchoParams(''),
          ),
        );
        await server.started.future;

        await clientToServer.close();
        await serverConn.done;
        server.complete.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(resultCap.disposeCount, equals(1));
      },
    );

    test(
      'one capability failing to dispose does not stop others in the same '
      'discarded result from being disposed',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        serverToClient.stream.listen((_) {});

        final failingCap = ThrowingDisposeCapability();
        final okCap = CountingCapability();
        final onDisposeErrors = <Object>[];
        final server = SlowCapResultServer([failingCap, okCap]);
        final serverConn = TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: server,
          onDisposeError: (error, stackTrace) => onDisposeErrors.add(error),
        );

        clientToServer.add(
          buildCallMessage(
            questionId: 1,
            targetImportId: 0,
            interfaceId: _echoInterfaceId,
            methodId: _pipelineMethodId,
            paramsBytes: _buildEchoParams(''),
          ),
        );
        await server.started.future;

        await clientToServer.close();
        await serverConn.done;
        server.complete.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(okCap.disposeCount, equals(1));
        expect(onDisposeErrors, hasLength(1));
        expect(onDisposeErrors.single, isA<StateError>());
      },
    );

    test(
      'debugExportCount / debugImportCount track an exchanged capability '
      'and return to zero after it is released',
      () async {
        // ChildPipelineServer returns a distinct capability (not itself) so
        // the pipelined result is a genuinely new export/import, not just a
        // second reference to the already-exported bootstrap capability.
        final (client, serverConn) = _makePipe(ChildPipelineServer());

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        // The bootstrap capability itself is export 0 / import 0 at this point.
        expect(serverConn.debugExportCount, equals(1));
        expect(client.debugImportCount, equals(1));

        final call = bootstrapCap.cap.beginDispatch(
          _echoInterfaceId,
          _pipelineMethodId,
          _buildEchoParams(''),
        );
        final pipelinedCap = call.pipelineResult(0);
        await call.result;
        await Future<void>.delayed(Duration.zero);

        expect(serverConn.debugExportCount, equals(2));
        expect(client.debugImportCount, equals(2));

        await pipelinedCap.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(serverConn.debugExportCount, equals(1));
        expect(client.debugImportCount, equals(1));

        await client.close();
        await serverConn.close();
      },
    );

    test(
      'debugCancellationCount / debugAnswerCount reflect an in-flight '
      'dispatch and settle back to zero once teardown completes',
      () async {
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

        // Dispatch is running: one live cancellation controller, one
        // in-flight answer.
        expect(serverConn.debugCancellationCount, equals(1));
        expect(serverConn.debugAnswerCount, equals(1));

        await clientToServer.close();
        await server.canceled.future.timeout(const Duration(milliseconds: 100));
        server.complete.complete();
        await serverConn.done;

        expect(serverConn.debugCancellationCount, equals(0));
        expect(serverConn.debugAnswerCount, equals(0));
      },
    );

    test(
      'exporting the same capability twice reuses the export id; only the '
      'final Release disposes it',
      () async {
        final incoming = StreamController<Uint8List>();
        final outgoingCaptured = <RpcMessage>[];
        final outgoing =
            StreamController<Uint8List>()
              ..stream.listen((b) => outgoingCaptured.add(parseRpcMessage(b)));

        final target = CountingCapability();
        final serverConn = TwoPartyRpcConnection.server(
          incoming: incoming.stream,
          outgoing: outgoing.sink,
          bootstrap: FixedCapServer(target),
        );

        // First call: server returns `target` as a result capability.
        incoming.add(
          buildCallMessage(
            questionId: 1,
            targetImportId: 0,
            interfaceId: _echoInterfaceId,
            methodId: _pipelineMethodId,
            paramsBytes: _buildEchoParams(''),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final return1 =
            outgoingCaptured
                .where(
                  (m) => m.type == RpcMessageType.return_ && m.answerId == 1,
                )
                .single;
        expect(return1.capTableDescriptors, hasLength(1));
        final exportId = return1.capTableDescriptors.single.id;
        // Export 0 is the bootstrap (FixedCapServer); export [exportId] is target.
        expect(serverConn.debugExportCount, equals(2));
        expect(target.disposeCount, equals(0));

        incoming.add(buildFinishMessage(1, releaseResultCaps: false));
        await Future<void>.delayed(Duration.zero);

        outgoingCaptured.clear();
        // Second call: the *same* target capability is returned again.
        incoming.add(
          buildCallMessage(
            questionId: 2,
            targetImportId: 0,
            interfaceId: _echoInterfaceId,
            methodId: _pipelineMethodId,
            paramsBytes: _buildEchoParams(''),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final return2 =
            outgoingCaptured
                .where(
                  (m) => m.type == RpcMessageType.return_ && m.answerId == 2,
                )
                .single;
        // Same capability -> the existing export id is reused, not a new one.
        expect(return2.capTableDescriptors.single.id, equals(exportId));
        expect(serverConn.debugExportCount, equals(2));

        incoming.add(buildFinishMessage(2, releaseResultCaps: false));
        await Future<void>.delayed(Duration.zero);

        // Peer now releases the two references it was granted, one at a time.
        incoming.add(buildReleaseMessage(exportId, 1));
        await Future<void>.delayed(Duration.zero);
        expect(
          target.disposeCount,
          equals(0),
          reason: 'one remote reference is still outstanding',
        );
        expect(serverConn.debugExportCount, equals(2));

        incoming.add(buildReleaseMessage(exportId, 1));
        await Future<void>.delayed(Duration.zero);
        expect(target.disposeCount, equals(1));
        expect(serverConn.debugExportCount, equals(1)); // only bootstrap remains

        await serverConn.close();
      },
    );

    test(
      'closing the connection while Bootstrap is in flight fails it instead '
      'of hanging, and a late Bootstrap Return is safely ignored',
      () async {
        final incoming = StreamController<Uint8List>();
        final outgoing = StreamController<Uint8List>()..stream.listen((_) {});

        final client = TwoPartyRpcConnection.client(
          incoming: incoming.stream,
          outgoing: outgoing.sink,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        // Bootstrap message sent; no Return has arrived yet.
        expect(client.debugPendingQuestionCount, equals(1));

        await client.close();

        // The pending bootstrap call must fail, not hang forever.
        await expectLater(
          bootstrapCap.echo('after-close-race'),
          throwsA(anything),
        );
        expect(client.debugPendingQuestionCount, equals(0));

        // A Bootstrap Return that was already in flight when close() ran
        // must be safely ignored — no crash, no state resurrected.
        incoming.add(buildBootstrapReturnMessage(answerId: 0, exportId: 0));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(client.debugPendingQuestionCount, equals(0));
      },
    );
  });

  group('TwoPartyRpcConnection — streaming flow control', () {
    test(
      'dispatchStreaming applies window backpressure and unblocks as calls '
      'are acked, in order',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();

        final server = QueuedSlowServer();
        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: server,
        );

        // Measure one real (empty) params message so the window arithmetic
        // below is exact regardless of framing overhead.
        final params = _buildEchoParams('');
        final messageSize = params.lengthInBytes;

        // windowSize = 2x message size: sends 1 and 2 fit (in-flight <=
        // 2*size, limit = window(2*size) + maxMessage(size) = 3*size); send
        // 3 does not (in-flight 3*size is not < limit 3*size).
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
          streamWindowSize: messageSize * 2,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        final cap = bootstrapCap.cap;

        final order = <int>[];
        Future<void> streamCall(int n) => cap
            .dispatchStreaming(_echoInterfaceId, _echoMethodId, params)
            .then((_) => order.add(n));

        unawaited(streamCall(1));
        unawaited(streamCall(2));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          order,
          equals([1, 2]),
          reason: 'first two calls fit in the window',
        );
        expect(server.dispatchCount, equals(2));

        unawaited(streamCall(3));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          order,
          equals([1, 2]),
          reason: 'third call is blocked by the full window, not yet sent '
              'to the flow-control caller — but it IS already on the wire',
        );
        // The call was still sent immediately despite being window-blocked
        // (message order on the wire is never delayed by flow control).
        expect(server.dispatchCount, equals(3));

        // Acking the oldest call frees enough window for the third send's
        // future to resolve.
        server.completeNext();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(order, equals([1, 2, 3]));

        server.completeNext();
        server.completeNext();
        await client.close();
      },
    );

    test(
      'a failed streaming call poisons that capability\'s flow-control '
      'window for later streaming calls, but not for regular calls',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();

        final server = QueuedSlowServer();
        TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverToClient.sink,
          bootstrap: server,
        );

        final params = _buildEchoParams('');
        final messageSize = params.lengthInBytes;

        // windowSize == one message: the first send is never blocked by its
        // own size, but a second concurrent send is — giving a
        // genuinely-blocked call to observe the poisoning propagate through.
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
          streamWindowSize: messageSize,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        final cap = bootstrapCap.cap;

        var firstResolved = false;
        unawaited(
          cap
              .dispatchStreaming(_echoInterfaceId, _echoMethodId, params)
              .then((_) => firstResolved = true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          firstResolved,
          isTrue,
          reason: 'the first send is never blocked by its own size',
        );

        // Attach the listener immediately so the pending rejection below
        // isn't briefly unobserved and flagged as an unhandled zone error.
        final blockedResult = cap.dispatchStreaming(
          _echoInterfaceId,
          _echoMethodId,
          params,
        );
        Object? blockedError;
        unawaited(blockedResult.catchError((Object e) => blockedError = e));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(server.dispatchCount, equals(2));
        expect(
          blockedError,
          isNull,
          reason: 'second send is still window-blocked, not yet failed',
        );

        // Failing the first call's ack poisons the flow controller: the
        // still-blocked second send now rejects with that failure.
        server.failNext(StateError('write failed'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(blockedError, isA<RpcException>());

        // Poisoning persists for later streaming sends on the same
        // capability — this one is rejected immediately, without even
        // waiting on its own ack.
        await expectLater(
          cap.dispatchStreaming(_echoInterfaceId, _echoMethodId, params),
          throwsA(isA<RpcException>()),
        );

        // But poisoning is scoped to the streaming flow controller, not the
        // capability itself — a regular (non-streaming) dispatch still
        // completes normally once acked.
        final regularResult = cap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          params,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        server.completeNext();
        server.completeNext();
        server.completeNext();
        await expectLater(regularResult, completes);

        await client.close();
      },
    );
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
      'server returns DeferredCapability as senderPromise and sends Resolve',
      () async {
        final clientToServer = StreamController<Uint8List>();
        final serverToClient = StreamController<Uint8List>();
        final serverCaptured = <Uint8List>[];
        final server = PromisedReturnServer();

        final serverIntercept =
            StreamController<Uint8List>()
              ..stream.listen((bytes) {
                serverCaptured.add(bytes);
                serverToClient.add(bytes);
              });

        final serverConn = TwoPartyRpcConnection.server(
          incoming: clientToServer.stream,
          outgoing: serverIntercept.sink,
          bootstrap: server,
        );
        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
        );

        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        serverCaptured.clear();
        final parent = bootstrapCap.cap.beginDispatch(
          _echoInterfaceId,
          _pipelineMethodId,
          _buildEchoParams(''),
        );
        final pipelinedCap = parent.pipelineResult(0);
        final pipelinedCall = pipelinedCap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('before-resolve'),
        );

        final ret = await _waitForMessageType(
          serverCaptured,
          RpcMessageType.return_,
        );
        expect(ret.isReturnResults, isTrue);
        expect(ret.capTableDescriptors, hasLength(1));
        expect(ret.capTableDescriptors.single.disc, 2);
        final promiseId = ret.capTableDescriptors.single.id;

        var pipelinedCompleted = false;
        pipelinedCall.then((_) => pipelinedCompleted = true).ignore();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(pipelinedCompleted, isFalse);

        server.completer.complete(EchoServer());
        final pipelinedResult = await pipelinedCall.timeout(
          const Duration(seconds: 2),
        );
        expect(
          _parseEchoResult(pipelinedResult.bytes),
          equals('echo: before-resolve'),
        );

        final resolve = await _waitForMessageType(
          serverCaptured,
          RpcMessageType.resolve,
        );
        expect(resolve.promiseId, promiseId);
        expect(resolve.isResolveCap, isTrue);
        expect(resolve.resolveCapDescriptor?.disc, 1);

        await parent.result;
        await client.close();
        await serverConn.close();
        await serverIntercept.close();
      },
    );

    test('server sends Resolve(exception) when senderPromise fails', () async {
      final clientToServer = StreamController<Uint8List>();
      final serverToClient = StreamController<Uint8List>();
      final serverCaptured = <Uint8List>[];
      final server = PromisedReturnServer();

      final serverIntercept =
          StreamController<Uint8List>()
            ..stream.listen((bytes) {
              serverCaptured.add(bytes);
              serverToClient.add(bytes);
            });

      final serverConn = TwoPartyRpcConnection.server(
        incoming: clientToServer.stream,
        outgoing: serverIntercept.sink,
        bootstrap: server,
      );
      final client = TwoPartyRpcConnection.client(
        incoming: serverToClient.stream,
        outgoing: clientToServer.sink,
      );

      final bootstrapCap = client.bootstrap(EchoClientFactory());
      await bootstrapCap.echo('warmup');

      serverCaptured.clear();
      final parent = bootstrapCap.cap.beginDispatch(
        _echoInterfaceId,
        _pipelineMethodId,
        _buildEchoParams(''),
      );
      final pipelinedCap = parent.pipelineResult(0);
      await parent.result;

      final ret = await _waitForMessageType(
        serverCaptured,
        RpcMessageType.return_,
      );
      final promiseId = ret.capTableDescriptors.single.id;

      server.completer.completeError(const RpcException('promise failed'));
      final resolve = await _waitForMessageType(
        serverCaptured,
        RpcMessageType.resolve,
      );
      expect(resolve.promiseId, promiseId);
      expect(resolve.isResolveException, isTrue);
      expect(resolve.exceptionReason, contains('promise failed'));

      await expectLater(
        pipelinedCap.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('after-failure'),
        ),
        throwsA(
          allOf(
            isA<RpcException>(),
            predicate<Object>((e) => e.toString().contains('promise failed')),
          ),
        ),
      );

      await client.close();
      await serverConn.close();
      await serverIntercept.close();
    });

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

      // A plain call/reply round-trip must leave both sides' internal
      // tables empty after close — nothing should ever have needed to
      // linger for a call this simple, including the bootstrap
      // export/import entry itself (teardown clears it, not just refcounting).
      for (final conn in [client, server]) {
        expect(conn.debugPendingQuestionCount, equals(0));
        expect(conn.debugExportCount, equals(0));
        expect(conn.debugImportCount, equals(0));
        expect(conn.debugAnswerCount, equals(0));
        expect(conn.debugCancellationCount, equals(0));
        expect(conn.debugEmbargoCount, equals(0));
      }
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

      // The rejected post-close call must not have left a phantom pending
      // question behind on the client.
      expect(client.debugPendingQuestionCount, equals(0));
      expect(server.debugPendingQuestionCount, equals(0));
    });
  });

  group('TwoPartyRpcConnection — List(Interface) over RPC', () {
    test(
      'server returns List(Interface) in result, client reads and calls each cap',
      () async {
        final server = ListCapsServer();
        final (client, serverConn) = _makePipe(server);
        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        final result = await bootstrapCap.cap.dispatch(
          _echoInterfaceId,
          _listCapsResultMethodId,
          DispatchResult.empty.bytes,
        );

        final root = MessageReader.deserialize(
          result.bytes,
        ).getRoot(_TextParamFactory());
        final rawList = root.getCapabilityListField(0);
        expect(rawList?.length, 2);

        final cap0 = result.caps[rawList![0]];
        final cap1 = result.caps[rawList[1]];

        final r0 = await cap0.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('foo'),
        );
        expect(_parseEchoResult(r0.bytes), 'echo: foo');

        final r1 = await cap1.dispatch(
          _echoInterfaceId,
          _echoMethodId,
          _buildEchoParams('bar'),
        );
        expect(_parseEchoResult(r1.bytes), 'echo: bar');

        await bootstrapCap.dispose();
        await client.close();
        await serverConn.close();
      },
    );

    test(
      'client sends List(Interface) in params, server reads and calls each cap',
      () async {
        final echoA = EchoServer();
        final echoB = EchoServer();
        final server = ListCapsServer();
        final (client, serverConn) = _makePipe(server);
        final bootstrapCap = client.bootstrap(EchoClientFactory());
        await bootstrapCap.echo('warmup');

        final mb = MessageBuilder();
        final list =
            mb.initRoot(_TextParamFactory()).initCapabilityListField(0, 2);
        list[0] = 0;
        list[1] = 1;

        final result = await bootstrapCap.cap.dispatch(
          _echoInterfaceId,
          _listCapsParamMethodId,
          mb.serialize(),
          paramsCapabilities: [echoA, echoB],
        );

        expect(_parseEchoResult(result.bytes), 'echo: a|echo: b');

        await bootstrapCap.dispose();
        await echoA.dispose();
        await echoB.dispose();
        await client.close();
        await serverConn.close();
      },
    );
  });

  // ─── Fix 1: synchronous exception in dispatchWithContext ─────────────────────

  group(
    'TwoPartyRpcConnection — synchronous dispatchWithContext exception',
    () {
      test('sync throw is returned as RPC exception, not leaked', () async {
        final (client, serverConn) = _makePipe(_SyncThrowingCapability());
        final bootstrapCap = client.bootstrap(EchoClientFactory());

        // The call must fail — the synchronous throw must be converted to a
        // Return(exception) rather than crashing the stream listener.
        await expectLater(
          bootstrapCap.echo('test'),
          throwsA(anything),
        );

        // Connection close must succeed (stream must not have crashed).
        await client.close();
        await serverConn.close();
      });

      test(
        'connection handles subsequent calls after sync throw',
        () async {
          final server = _FirstCallSyncThrowCapability();
          final (client, serverConn) = _makePipe(server);
          final bootstrapCap = client.bootstrap(EchoClientFactory());

          // First call: server throws synchronously.
          await expectLater(
            bootstrapCap.echo('call1'),
            throwsA(anything),
          );

          // Second call: server echoes normally.
          final result = await bootstrapCap.echo('call2');
          expect(result, 'echo: call2');

          await client.close();
          await serverConn.close();
        },
      );
    },
  );

  // ─── Malformed incoming bytes: _runMessageLoop try/catch ─────────────────────

  group('TwoPartyRpcConnection — malformed incoming message teardown', () {
    // A valid Cap'n Proto frame (1 segment, 1 word) whose root struct pointer
    // references a data section that lies outside the segment bounds.
    // parseRpcMessage() throws DecodeException when processing this frame.
    //
    // Header (8 bytes): numSegments-1=0 (→1 seg), seg0 size=1 word
    // Segment (8 bytes): struct ptr offset=1, dataWords=1, ptrWords=0
    //   → struct data starts at word 2 but segment only has 1 word → out-of-bounds
    final malformedFrame = Uint8List.fromList([
      0x00, 0x00, 0x00, 0x00, // numSegments-1 = 0 → 1 segment
      0x01, 0x00, 0x00, 0x00, // segment 0: 1 word (8 bytes)
      0x04, 0x00, 0x00, 0x00, // struct ptr: kind=0, offset=1
      0x01, 0x00, 0x00, 0x00, // dataWords=1, ptrWords=0
    ]);

    test(
      'malformed frame tears down connection and rejects pending calls',
      () async {
        // Manually wire up a client without a real server.
        final serverToClient = StreamController<Uint8List>();
        final clientToServer = StreamController<Uint8List>()
          ..stream.listen((_) {});

        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
        );

        // Kick off an echo call. It awaits bootstrap resolution internally,
        // creating a pending question that tearDown must reject.
        final callFuture = client.bootstrap(EchoClientFactory()).echo('hello');

        // Inject the malformed frame. parseRpcMessage() will throw
        // DecodeException, which the try/catch in _runMessageLoop catches
        // and converts to a _tearDown() call.
        serverToClient.add(malformedFrame);

        // The pending call must fail (tearDown rejected the bootstrap completer).
        await expectLater(callFuture, throwsA(anything));

        // Teardown must leave every internal table empty, not just reject
        // the pending call.
        expect(client.debugPendingQuestionCount, equals(0));
        expect(client.debugExportCount, equals(0));
        expect(client.debugImportCount, equals(0));
        expect(client.debugAnswerCount, equals(0));
        expect(client.debugCancellationCount, equals(0));
        expect(client.debugEmbargoCount, equals(0));

        await serverToClient.close();
        await clientToServer.close();
      },
    );

    test(
      'malformed frame tears down connection cleanly (no pending calls)',
      () async {
        final serverToClient = StreamController<Uint8List>();
        final clientToServer = StreamController<Uint8List>()
          ..stream.listen((_) {});

        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
        );

        serverToClient.add(malformedFrame);

        // Give the event loop a chance to process the malformed frame.
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // After teardown, new calls must be rejected immediately.
        // bootstrap() may throw synchronously, so wrap in Future.sync.
        await expectLater(
          Future.sync(() => client.bootstrap(EchoClientFactory()).echo('hello')),
          throwsA(anything),
        );

        expect(client.debugPendingQuestionCount, equals(0));
        expect(client.debugExportCount, equals(0));
        expect(client.debugImportCount, equals(0));
        expect(client.debugAnswerCount, equals(0));
        expect(client.debugCancellationCount, equals(0));
        expect(client.debugEmbargoCount, equals(0));

        await serverToClient.close();
        await clientToServer.close();
      },
    );
  });

  group('TwoPartyRpcConnection — Bootstrap Finish message', () {
    test(
      'client sends Finish after receiving Bootstrap Return',
      () async {
        final serverToClient = StreamController<Uint8List>();
        final clientToServer = StreamController<Uint8List>();
        final captured = <RpcMessage>[];
        clientToServer.stream.listen(
          (bytes) => captured.add(parseRpcMessage(bytes)),
        );

        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
        );

        // Trigger bootstrap — sends Bootstrap(QID=0).
        final stub = client.bootstrap(EchoClientFactory());

        // Let the Bootstrap message reach the captured list.
        await Future<void>.delayed(Duration.zero);

        // Simulate server sending Bootstrap Return with one senderHosted cap.
        serverToClient.add(
          buildBootstrapReturnMessage(answerId: 0, exportId: 0),
        );

        // Let the Return be processed and the Finish be sent.
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Verify Bootstrap was sent first (QID=0).
        expect(
          captured,
          contains(
            predicate<RpcMessage>(
              (m) =>
                  m.type == RpcMessageType.bootstrap && m.questionId == 0,
            ),
          ),
        );

        // Verify Finish(QID=0, releaseResultCaps=false) was sent after.
        final finishMsg = captured.firstWhere(
          (m) => m.type == RpcMessageType.finish && m.questionId == 0,
          orElse: () => throw TestFailure('expected Finish(0) but not found'),
        );
        expect(finishMsg.releaseResultCaps, isFalse);

        // Verify Finish appears after Bootstrap in message order.
        final bootstrapIndex = captured.indexWhere(
          (m) => m.type == RpcMessageType.bootstrap && m.questionId == 0,
        );
        final finishIndex = captured.indexWhere(
          (m) => m.type == RpcMessageType.finish && m.questionId == 0,
        );
        expect(finishIndex, greaterThan(bootstrapIndex));

        // The bootstrap cap must be usable after the exchange completes.
        stub.dispose();

        await serverToClient.close();
        await clientToServer.close();
      },
    );

    test(
      'client sends Finish even when Bootstrap Return carries an exception',
      () async {
        final serverToClient = StreamController<Uint8List>();
        final clientToServer = StreamController<Uint8List>();
        final captured = <RpcMessage>[];
        clientToServer.stream.listen(
          (bytes) => captured.add(parseRpcMessage(bytes)),
        );

        final client = TwoPartyRpcConnection.client(
          incoming: serverToClient.stream,
          outgoing: clientToServer.sink,
        );

        final stub = client.bootstrap(EchoClientFactory());

        await Future<void>.delayed(Duration.zero);

        // Simulate server sending a Bootstrap Return exception.
        serverToClient.add(
          buildReturnExceptionMessage(
            answerId: 0,
            reason: 'no bootstrap cap',
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Finish(QID=0) must still be sent, even for a failed bootstrap.
        final finishMsg = captured.firstWhere(
          (m) => m.type == RpcMessageType.finish && m.questionId == 0,
          orElse: () => throw TestFailure('expected Finish(0) but not found'),
        );
        expect(finishMsg.releaseResultCaps, isFalse);

        // The stub itself should fail.
        await expectLater(stub.echo('hello'), throwsA(isA<RpcException>()));

        await serverToClient.close();
        await clientToServer.close();
      },
    );
  });
}
