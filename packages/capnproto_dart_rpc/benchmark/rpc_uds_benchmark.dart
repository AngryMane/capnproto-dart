// RPC round-trip benchmark over a real Unix domain socket — unlike
// rpc_benchmark.dart's in-memory pipe (which isolates protocol/dispatch
// overhead from transport), this measures a genuine cross-process-shaped
// transport: real `write()`/`read()` syscalls and kernel-mediated socket
// buffers, the same class of overhead a real deployment (two separate
// processes on the same machine) would pay. Client and server still run in
// this same process/isolate (Dart's event loop drives both ends of the
// socket), but the socket itself is real, not an in-memory Stream/Sink.
//
// Also exercises several payload sizes in one run — rpc_benchmark.dart only
// covers a single small payload, so it can't show how the relative cost of
// per-call fixed overhead (dispatch, syscalls, message framing) changes as
// the actual message content grows.
//
// The echo Capability/client and benchmark reporting are shared with
// rpc_ws_benchmark.dart via echo_rpc_benchmark_support.dart, so the two
// transports are measured with identical methodology and this file only
// differs in how the socket itself is set up.
//
// Run with: dart run benchmark/rpc_uds_benchmark.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:capnproto_dart_rpc/src/rpc/two_party_connection.dart';

import 'echo_rpc_benchmark_support.dart';

/// Adapts a `dart:io` [Socket] (an [IOSink]) to [StreamSink<Uint8List>] —
/// same pattern [RpcSystem]'s own `tcp://`/`ws://` support uses internally
/// (`_SocketSink` in rpc_system.dart, private to that library file).
class _SocketSink implements StreamSink<Uint8List> {
  final Socket _socket;
  _SocketSink(this._socket);

  @override
  void add(Uint8List data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) =>
      _socket.addStream(stream);

  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _socket.done;
}

Future<(TwoPartyRpcConnection, TwoPartyRpcConnection, ServerSocket)>
_connectOverUds(Capability serverBootstrap) async {
  final socketPath =
      '${Directory.systemTemp.path}/capnproto_dart_rpc_uds_bench_$pid.sock';
  final socketFile = File(socketPath);
  if (await socketFile.exists()) await socketFile.delete();

  final serverAddress = InternetAddress(
    socketPath,
    type: InternetAddressType.unix,
  );
  final serverSocket = await ServerSocket.bind(serverAddress, 0);

  late final TwoPartyRpcConnection serverConn;
  final serverReady = Completer<void>();
  serverSocket.listen((socket) {
    serverConn = TwoPartyRpcConnection.server(
      incoming: socket,
      outgoing: _SocketSink(socket),
      bootstrap: serverBootstrap,
    );
    serverReady.complete();
  });

  final clientSocket = await Socket.connect(serverAddress, 0);
  final clientConn = TwoPartyRpcConnection.client(
    incoming: clientSocket,
    outgoing: _SocketSink(clientSocket),
  );

  await serverReady.future;
  return (clientConn, serverConn, serverSocket);
}

Future<void> main(List<String> args) async {
  final suiteSuffix = args.isNotEmpty ? ' ${args[0]}' : '';

  final (client, server, serverSocket) = await _connectOverUds(EchoServer());
  final echoClient = client.bootstrap(EchoClientFactory());

  final results = <BenchmarkResult>[];
  for (final size in payloadSizes) {
    final payload = 'x' * size;

    for (var i = 0; i < warmupIterations; i++) {
      await echoClient.echo(payload);
    }

    final watch = Stopwatch()..start();
    for (var i = 0; i < iterationsPerSize; i++) {
      await echoClient.echo(payload);
    }
    watch.stop();

    results.add(
      BenchmarkResult(
        'echo round-trip (${sizeLabel(size)} payload)',
        iterationsPerSize,
        watch.elapsedMicroseconds,
      ),
    );
  }

  await client.close();
  await server.close();
  await serverSocket.close();

  reportBenchmarks('capnproto_dart_rpc: UDS echo call$suiteSuffix', results);
}
