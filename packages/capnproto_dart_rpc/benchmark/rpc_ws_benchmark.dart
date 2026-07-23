// RPC round-trip benchmark over a real WebSocket connection — companion to
// rpc_uds_benchmark.dart, measuring the transport that routes through
// TwoPartyRpcConnection's `preFramed` (deserializeFramedStreamRaw) path
// instead of the generic byte-accumulation deframer UDS/TCP use.
//
// Reuses RpcSystem.serve/RpcSystem.connect (the same entry points
// applications use for `ws://`) for all socket/HTTP-upgrade wiring, and the
// echo Capability/client and benchmark reporting from
// echo_rpc_benchmark_support.dart — so this file only differs from
// rpc_uds_benchmark.dart in how the connection is established, keeping the
// two transports' results directly comparable.
//
// Run with: dart run benchmark/rpc_ws_benchmark.dart

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';

import 'echo_rpc_benchmark_support.dart';

Future<(RpcConnection, RpcServer)> _connectOverWebSocket(
  Capability serverBootstrap,
) async {
  final server = await RpcSystem.serve(
    Uri.parse('ws://127.0.0.1:0'),
    serverBootstrap,
  );
  final client = await RpcSystem.connect(
    Uri.parse('ws://127.0.0.1:${server.port}'),
  );
  return (client, server);
}

Future<void> main(List<String> args) async {
  final suiteSuffix = args.isNotEmpty ? ' ${args[0]}' : '';

  final (client, server) = await _connectOverWebSocket(EchoServer());
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

  reportBenchmarks(
    'capnproto_dart_rpc: WebSocket echo call$suiteSuffix',
    results,
  );
}
