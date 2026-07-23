// Minimal RPC round-trip latency benchmark: an in-memory (no real socket)
// client/server pair exchanging a trivial text-echo call, matching the
// hand-rolled Capability pattern used by packages/capnproto_dart_rpc/test/
// rpc_test.dart (no capnpc-generated code needed).
//
// Run with: dart run benchmark/rpc_benchmark.dart
//
// Prints one JSON line (machine-readable) followed by a Markdown table
// (human-readable), and — when running under GitHub Actions — appends the
// same table to $GITHUB_STEP_SUMMARY so results show up directly on the
// workflow run's summary page.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:capnproto_dart_rpc/src/rpc/two_party_connection.dart';

const _iterations = 5000;
const _warmupIterations = 200;

const int _echoInterfaceId = 0x0001;
const int _echoMethodId = 0;

final class _TextParamReader extends StructReader {
  _TextParamReader(super.raw);
}

final class _TextParamBuilder extends StructBuilder {
  _TextParamBuilder(super.raw);

  @override
  StructReader asReader() => throw UnimplementedError();
}

final class _TextParamFactory
    extends StructFactory<_TextParamReader, _TextParamBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 1;
  @override
  _TextParamReader fromRawReader(RawStructReader r) => _TextParamReader(r);
  @override
  _TextParamBuilder fromRawBuilder(RawStructBuilder r) =>
      _TextParamBuilder(r);
}

String? _parseEchoResult(RpcPayload payload) =>
    payload.getTyped(_TextParamFactory()).getTextField(0);

class _EchoServer extends Capability {
  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    final req = params.getTyped(_TextParamFactory());
    final message = req.getTextField(0) ?? '';
    final mb = MessageBuilder();
    final out = mb.initRoot(_TextParamFactory());
    out.setTextField(0, 'echo: $message');
    return DispatchResult(payload: RpcPayload.fromBuilder(out));
  }

  @override
  Future<void> dispose() async {}
}

class _EchoClient extends Capability {
  final Capability cap;
  _EchoClient(this.cap);

  Future<String> echo(String message) async {
    final result = await cap.dispatchBuilding(
      _echoInterfaceId,
      _echoMethodId,
      (anyPtr) =>
          anyPtr.initStruct(_TextParamFactory()).setTextField(0, message),
    );
    return _parseEchoResult(result.payload) ?? '';
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => Future.error(UnsupportedError('client stub'));

  @override
  Future<void> dispose() => cap.dispose();
}

class _EchoClientFactory extends CapabilityFactory<_EchoClient> {
  @override
  _EchoClient fromCapability(Capability cap) => _EchoClient(cap);
}

/// Creates a bidirectional in-memory pipe: returns (client conn, server
/// conn) — no real socket involved, so this measures RPC protocol/dispatch
/// overhead in isolation from transport latency.
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

Future<void> main(List<String> args) async {
  final suiteSuffix = args.isNotEmpty ? ' ${args[0]}' : '';

  final (client, server) = _makePipe(_EchoServer());
  final echoClient = client.bootstrap(_EchoClientFactory());

  for (var i = 0; i < _warmupIterations; i++) {
    await echoClient.echo('warmup-$i');
  }

  final watch = Stopwatch()..start();
  for (var i = 0; i < _iterations; i++) {
    await echoClient.echo('message-$i');
  }
  watch.stop();

  await client.close();
  await server.close();

  reportBenchmarks('capnproto_dart_rpc: in-memory echo call$suiteSuffix', [
    BenchmarkResult('echo round-trip', _iterations, watch.elapsedMicroseconds),
  ]);
}

/// A single benchmark's timing result.
class BenchmarkResult {
  final String name;
  final int iterations;
  final int elapsedMicroseconds;

  BenchmarkResult(this.name, this.iterations, this.elapsedMicroseconds);

  double get opsPerSecond => iterations / (elapsedMicroseconds / 1e6);
  double get microsecondsPerOp => elapsedMicroseconds / iterations;
}

/// Prints [results] as a JSON line and a Markdown table, and appends the
/// table to `$GITHUB_STEP_SUMMARY` when running in a GitHub Actions job.
void reportBenchmarks(String suiteName, List<BenchmarkResult> results) {
  stdout.writeln(
    jsonEncode({
      'suite': suiteName,
      'results': [
        for (final r in results)
          {
            'name': r.name,
            'iterations': r.iterations,
            'elapsedMicroseconds': r.elapsedMicroseconds,
            'opsPerSecond': r.opsPerSecond,
            'microsecondsPerOp': r.microsecondsPerOp,
          },
      ],
    }),
  );

  final table = StringBuffer()
    ..writeln('### Benchmark: $suiteName')
    ..writeln()
    ..writeln('| Benchmark | Iterations | ops/sec | µs/op |')
    ..writeln('|---|---:|---:|---:|');
  for (final r in results) {
    table.writeln(
      '| ${r.name} | ${r.iterations} | '
      '${r.opsPerSecond.toStringAsFixed(0)} | '
      '${r.microsecondsPerOp.toStringAsFixed(2)} |',
    );
  }
  stdout.write(table.toString());

  final summaryPath = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (summaryPath != null) {
    File(summaryPath).writeAsStringSync('\n$table\n', mode: FileMode.append);
  }
}
