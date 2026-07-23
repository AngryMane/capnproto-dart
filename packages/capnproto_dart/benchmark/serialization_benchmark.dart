// Minimal serialization/deserialization throughput benchmark.
//
// Run with: dart run benchmark/serialization_benchmark.dart
//
// Prints one JSON line (machine-readable) followed by a Markdown table
// (human-readable), and — when running under GitHub Actions — appends the
// same table to $GITHUB_STEP_SUMMARY so results show up directly on the
// workflow run's summary page.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

const _iterations = 200000;
const _warmupIterations = 5000;

final class _MetricsReader extends StructReader {
  _MetricsReader(super.raw);
  bool get flag => getBoolField(0);
  int get count => getInt32Field(4);
  int get total => getInt64Field(8);
  double get ratio => getFloat64Field(16);
  String? get label => getTextField(0);
}

final class _MetricsBuilder extends StructBuilder {
  _MetricsBuilder(super.raw);
  set flag(bool v) => setBoolField(0, v);
  set count(int v) => setInt32Field(4, v);
  set total(int v) => setInt64Field(8, v);
  set ratio(double v) => setFloat64Field(16, v);
  set label(String? v) => setTextField(0, v);

  @override
  _MetricsReader asReader() => throw UnimplementedError();
}

final class _MetricsFactory
    extends StructFactory<_MetricsReader, _MetricsBuilder> {
  @override
  int get dataWords => 3;
  @override
  int get ptrWords => 1;
  @override
  _MetricsReader fromRawReader(RawStructReader raw) => _MetricsReader(raw);
  @override
  _MetricsBuilder fromRawBuilder(RawStructBuilder raw) =>
      _MetricsBuilder(raw);
}

final _factory = _MetricsFactory();

// ---------------------------------------------------------------------------
// Message-size matrix: a single Data field lets us hit an arbitrary target
// serialized size directly, to see how encode/decode throughput scales
// beyond the one small fixed shape above (see performance.md's benchmark
// coverage notes).
// ---------------------------------------------------------------------------

final class _BlobReader extends StructReader {
  _BlobReader(super.raw);
  Uint8List? get payload => getDataField(0);
}

final class _BlobBuilder extends StructBuilder {
  _BlobBuilder(super.raw);
  set payload(Uint8List? v) => setDataField(0, v);

  @override
  _BlobReader asReader() => throw UnimplementedError();
}

final class _BlobFactory extends StructFactory<_BlobReader, _BlobBuilder> {
  @override
  int get dataWords => 0;
  @override
  int get ptrWords => 1;
  @override
  _BlobReader fromRawReader(RawStructReader raw) => _BlobReader(raw);
  @override
  _BlobBuilder fromRawBuilder(RawStructBuilder raw) => _BlobBuilder(raw);
}

final _blobFactory = _BlobFactory();

// Iteration counts scale down as message size grows so each entry still
// finishes in roughly the same wall-clock time.
const _messageSizes = <String, int>{
  '32B': 32,
  '256B': 256,
  '2KiB': 2 * 1024,
  '8KiB': 8 * 1024,
  '64KiB': 64 * 1024,
  '1MiB': 1024 * 1024,
};

const _sizeIterations = <String, int>{
  '32B': 100000,
  '256B': 100000,
  '2KiB': 50000,
  '8KiB': 20000,
  '64KiB': 4000,
  '1MiB': 400,
};

Uint8List _buildPayload(int size) {
  final payload = Uint8List(size);
  for (var i = 0; i < size; i++) {
    payload[i] = i & 0xFF;
  }
  return payload;
}

Uint8List _encodeBlob(Uint8List payload) {
  final message = MessageBuilder();
  final root = message.initRoot(_blobFactory);
  root.payload = payload;
  return message.serialize();
}

int _decodeBlob(Uint8List bytes) {
  final reader = MessageReader.deserialize(bytes);
  return reader.getRoot(_blobFactory).payload?.length ?? 0;
}

Uint8List _encodeOnce(int i) {
  final message = MessageBuilder();
  final root = message.initRoot(_factory);
  root.flag = i.isEven;
  root.count = i;
  root.total = i * 1000000000;
  root.ratio = i / 3;
  root.label = 'benchmark-message-$i';
  return message.serialize();
}

Uint8List _encodeOnceReusing(MessageBuilder message, int i) {
  final root = message.initRoot(_factory);
  root.flag = i.isEven;
  root.count = i;
  root.total = i * 1000000000;
  root.ratio = i / 3;
  root.label = 'benchmark-message-$i';
  return message.serialize();
}

int _decodeOnce(Uint8List bytes) {
  final reader = MessageReader.deserialize(bytes);
  final root = reader.getRoot(_factory);
  var acc = root.count;
  if (root.flag) acc += 1;
  acc += root.total.remainder(97);
  acc += root.ratio.round();
  acc += root.label?.length ?? 0;
  return acc;
}

void main(List<String> args) {
  final suiteSuffix = args.isNotEmpty ? ' ${args[0]}' : '';

  for (var i = 0; i < _warmupIterations; i++) {
    _decodeOnce(_encodeOnce(i));
  }

  final encodeWatch = Stopwatch()..start();
  for (var i = 0; i < _iterations; i++) {
    _encodeOnce(i);
  }
  encodeWatch.stop();

  // Reuses one MessageBuilder across every iteration via reset() instead of
  // constructing a fresh MessageBuilder (and its ArenaBuilder/SegmentBuilder/
  // backing buffer) each time — see MessageBuilder.reset's doc comment.
  final reusedMessage = MessageBuilder();
  for (var i = 0; i < _warmupIterations; i++) {
    _encodeOnceReusing(reusedMessage, i);
    reusedMessage.reset();
  }
  final encodeReusingWatch = Stopwatch()..start();
  for (var i = 0; i < _iterations; i++) {
    _encodeOnceReusing(reusedMessage, i);
    reusedMessage.reset();
  }
  encodeReusingWatch.stop();

  final sample = _encodeOnce(0);
  var checksum = 0;
  final decodeWatch = Stopwatch()..start();
  for (var i = 0; i < _iterations; i++) {
    checksum += _decodeOnce(sample);
  }
  decodeWatch.stop();
  // Forces the decoded fields to actually be used, so the loop above can't
  // be optimized away as dead code.
  stderr.writeln('# checksum (ignore): $checksum');

  reportBenchmarks('capnproto_dart: serialization$suiteSuffix', [
    BenchmarkResult(
      'encode (build + serialize)',
      _iterations,
      encodeWatch.elapsedMicroseconds,
    ),
    BenchmarkResult(
      'encode (reused MessageBuilder + reset())',
      _iterations,
      encodeReusingWatch.elapsedMicroseconds,
    ),
    BenchmarkResult(
      'decode (deserialize + read all fields)',
      _iterations,
      decodeWatch.elapsedMicroseconds,
    ),
  ]);

  final sizeResults = <BenchmarkResult>[];
  for (final entry in _messageSizes.entries) {
    final label = entry.key;
    final payload = _buildPayload(entry.value);
    final sizeIterations = _sizeIterations[label]!;
    final warmup = (sizeIterations ~/ 20).clamp(1, _warmupIterations);

    for (var i = 0; i < warmup; i++) {
      _decodeBlob(_encodeBlob(payload));
    }

    final blobEncodeWatch = Stopwatch()..start();
    for (var i = 0; i < sizeIterations; i++) {
      _encodeBlob(payload);
    }
    blobEncodeWatch.stop();

    final blobSample = _encodeBlob(payload);
    var blobChecksum = 0;
    final blobDecodeWatch = Stopwatch()..start();
    for (var i = 0; i < sizeIterations; i++) {
      blobChecksum += _decodeBlob(blobSample);
    }
    blobDecodeWatch.stop();
    stderr.writeln('# checksum (ignore): $blobChecksum');

    sizeResults.add(
      BenchmarkResult(
        'encode $label',
        sizeIterations,
        blobEncodeWatch.elapsedMicroseconds,
      ),
    );
    sizeResults.add(
      BenchmarkResult(
        'decode $label',
        sizeIterations,
        blobDecodeWatch.elapsedMicroseconds,
      ),
    );
  }
  reportBenchmarks(
    'capnproto_dart: serialization by message size$suiteSuffix',
    sizeResults,
  );
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
