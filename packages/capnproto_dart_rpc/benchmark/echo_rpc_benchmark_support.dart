// Shared echo Capability/client, benchmark reporting, and payload-size
// constants used by both rpc_uds_benchmark.dart and rpc_ws_benchmark.dart —
// factored out so the two transports are measured with identical
// methodology (same schema, same payload sizes, same iteration counts, same
// report format) and only their transport setup differs.

import 'dart:convert';
import 'dart:io';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';

const iterationsPerSize = 2000;
const warmupIterations = 100;
const payloadSizes = [0, 64, 1024, 16384, 65536];

const echoInterfaceId = 0x0001;
const echoMethodId = 0;

final class TextParamReader extends StructReader {
  TextParamReader(super.raw);
}

final class TextParamBuilder extends StructBuilder {
  TextParamBuilder(super.raw);

  @override
  StructReader asReader() => throw UnimplementedError();
}

final class TextParamFactory
    extends StructFactory<TextParamReader, TextParamBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 1;
  @override
  TextParamReader fromRawReader(RawStructReader r) => TextParamReader(r);
  @override
  TextParamBuilder fromRawBuilder(RawStructBuilder r) => TextParamBuilder(r);
}

String? parseEchoResult(RpcPayload payload) =>
    payload.getTyped(TextParamFactory()).getTextField(0);

class EchoServer extends Capability {
  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    final req = params.getTyped(TextParamFactory());
    final message = req.getTextField(0) ?? '';
    final mb = MessageBuilder();
    final out = mb.initRoot(TextParamFactory());
    out.setTextField(0, message);
    return DispatchResult(payload: RpcPayload.fromBuilder(out));
  }

  @override
  Future<void> dispose() async {}
}

class EchoClient extends Capability {
  final Capability cap;
  EchoClient(this.cap);

  Future<String> echo(String message) async {
    final result = await cap.dispatchBuilding(
      echoInterfaceId,
      echoMethodId,
      (anyPtr) =>
          anyPtr.initStruct(TextParamFactory()).setTextField(0, message),
    );
    return parseEchoResult(result.payload) ?? '';
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

class EchoClientFactory extends CapabilityFactory<EchoClient> {
  @override
  EchoClient fromCapability(Capability cap) => EchoClient(cap);
}

String sizeLabel(int bytes) {
  if (bytes == 0) return '0B';
  if (bytes < 1024) return '${bytes}B';
  return '${bytes ~/ 1024}KiB';
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

/// Prints [results] as a JSON line and a Markdown table (human-readable),
/// and appends the table to `$GITHUB_STEP_SUMMARY` when running in a GitHub
/// Actions job.
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
