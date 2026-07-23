// Packed-encoding throughput benchmark across word patterns that stress
// different code paths in packBytes/unpackBytes:
//  - sparse zero: mostly zero words (typical Cap'n Proto padding) → long
//    zero runs, few literal words.
//  - dense nonzero: every word fully non-zero → long literal runs.
//  - mixed: zero/non-zero words alternate → no run-length grouping is
//    possible, so throughput is dominated by per-word overhead rather than
//    bulk copy/fill throughput.
//
// Run with: dart run benchmark/packed_benchmark.dart
//
// Prints one JSON line (machine-readable) followed by a Markdown table
// (human-readable), and — when running under GitHub Actions — appends the
// same table to $GITHUB_STEP_SUMMARY, matching serialization_benchmark.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:capnproto_dart/src/stream/packed_codec.dart';

const _wordCount = 8192; // 64KiB decoded per message
const _warmupIterations = 200;

Uint8List _words(int Function(int wordIndex) pattern) {
  final data = Uint8List(_wordCount * 8);
  for (var w = 0; w < _wordCount; w++) {
    final v = pattern(w);
    if (v == 0) continue;
    for (var b = 0; b < 8; b++) {
      final byte = (v + b) & 0xFF;
      data[w * 8 + b] = byte == 0 ? 1 : byte; // guarantee the word is non-zero
    }
  }
  return data;
}

final _scenarios = <String, Uint8List>{
  'sparse zero (1/64 words non-zero)': _words((w) => w % 64 == 0 ? w + 1 : 0),
  'dense nonzero (all words non-zero)': _words((w) => w + 1),
  'mixed (alternating zero/non-zero)': _words((w) => w.isEven ? 0 : w + 1),
};

const _iterations = <String, int>{
  'sparse zero (1/64 words non-zero)': 8000,
  'dense nonzero (all words non-zero)': 4000,
  'mixed (alternating zero/non-zero)': 4000,
};

void main(List<String> args) {
  final suiteSuffix = args.isNotEmpty ? ' ${args[0]}' : '';
  final results = <BenchmarkResult>[];

  for (final entry in _scenarios.entries) {
    final label = entry.key;
    final raw = entry.value;
    final iterations = _iterations[label]!;
    final packed = packBytes(raw);

    for (var i = 0; i < _warmupIterations; i++) {
      unpackBytes(packBytes(raw));
    }

    final packWatch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      packBytes(raw);
    }
    packWatch.stop();

    final unpackWatch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      unpackBytes(packed);
    }
    unpackWatch.stop();

    stderr.writeln(
      '# $label: raw=${raw.length}B packed=${packed.length}B '
      'ratio=${(packed.length / raw.length).toStringAsFixed(3)}',
    );

    results.add(
      BenchmarkResult(
        'pack — $label',
        iterations,
        packWatch.elapsedMicroseconds,
      ),
    );
    results.add(
      BenchmarkResult(
        'unpack — $label',
        iterations,
        unpackWatch.elapsedMicroseconds,
      ),
    );
  }

  reportBenchmarks('capnproto_dart: packed encoding$suiteSuffix', results);
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
