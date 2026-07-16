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

// A minimal StructFactory for a struct with 0 dataWords and 1 ptrWord (Text).
final class _TextParamFactory
    extends StructFactory<_TextParamReader, _TextParamBuilder> {
  @override int get dataWords => 0;
  @override int get ptrWords => 1;
  @override _TextParamReader fromRawReader(RawStructReader r) =>
      _TextParamReader(r);
  @override _TextParamBuilder fromRawBuilder(RawStructBuilder r) =>
      _TextParamBuilder(r);
}

class _TextParamReader extends StructReader {
  _TextParamReader(super.raw);
}

class _TextParamBuilder extends StructBuilder {
  _TextParamBuilder(super.raw);
  @override StructReader asReader() => throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Echo server implementation
// ---------------------------------------------------------------------------

class EchoServer extends Capability {
  @override
  Future<DispatchResult> dispatch(
      int interfaceId, int methodId, Uint8List params, {
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
        _echoInterfaceId, _echoMethodId, _buildEchoParams(message));
    return _parseEchoResult(result.bytes) ?? '';
  }

  @override
  Future<DispatchResult> dispatch(int iid, int mid, Uint8List params, {
      List<Capability> paramsCapabilities = const [],
      }) =>
      Future.error(UnsupportedError('client stub'));

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
    Capability serverBootstrap) {
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
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

    test('return results round-trip', () {
      // Build a valid Cap'n Proto message to use as results.
      final mb = MessageBuilder();
      mb.initRoot(_TextParamFactory()).setTextField(0, 'world');
      final results = mb.serialize();

      final bytes = buildReturnResultsMessage(
          answerId: 99, resultsBytes: results);
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.return_);
      expect(msg.answerId, 99);
      expect(msg.isReturnResults, isTrue);
      // Verify the results round-trip correctly (semantic equality).
      final resultsMr = MessageReader.deserialize(msg.resultsBytes!);
      expect(resultsMr.getRoot(_TextParamFactory()).getTextField(0), 'world');
    });

    test('return exception round-trip', () {
      final bytes = buildReturnExceptionMessage(
          answerId: 5, reason: 'something broke');
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.return_);
      expect(msg.answerId, 5);
      expect(msg.isReturnException, isTrue);
      expect(msg.exceptionReason, 'something broke');
    });

    test('bootstrap return round-trip (capTable)', () {
      final bytes =
          buildBootstrapReturnMessage(answerId: 1, exportId: 42);
      final msg = parseRpcMessage(bytes);
      expect(msg.type, RpcMessageType.return_);
      expect(msg.answerId, 1);
      expect(msg.isReturnResults, isTrue);
      expect(msg.capTableExportIds, [42]);
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
      mangled[17] = 0;  // disc hi byte
      expect(parseRpcMessage(mangled).type, equals(RpcMessageType.other));
    });
  });

  group('TwoPartyRpcConnection — RPC-003 receiverHosted (imported cap returned to same peer)', () {
    test('capability received from server and sent back arrives as server-side object', () async {
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
    });

    test('capTable wire encoding uses disc=3 (receiverHosted) for imported cap', () async {
      // Intercept the bytes going from client to server.
      final clientToServer = StreamController<Uint8List>();
      final serverToClient = StreamController<Uint8List>();
      final captured = <Uint8List>[];

      final interceptSink = StreamController<Uint8List>()
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
      final callWithCap = captured
          .map(parseRpcMessage)
          .where((m) => m.type == RpcMessageType.call && m.paramsCapTable.isNotEmpty)
          .toList();

      expect(callWithCap, hasLength(1));
      // disc=3 means receiverHosted — the peer's own export, no proxy.
      expect(callWithCap.first.paramsCapTable.first.$1, equals(3));

      await client.close();
      await interceptSink.close();
    });
  });

  group('TwoPartyRpcConnection — RPC-007 Unimplemented for unknown messages', () {
    test('server sends Unimplemented when it receives a message with unknown disc', () async {
      final serverInput = StreamController<Uint8List>();
      final serverOutput = StreamController<Uint8List>();
      final serverReceived = <RpcMessage>[];

      serverOutput.stream.listen((bytes) => serverReceived.add(parseRpcMessage(bytes)));

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
        reason: 'server should reply with Unimplemented for unknown message disc',
      );

      await serverInput.close();
    });
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
          _echoInterfaceId, 99, _buildEchoParams('x'));
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
