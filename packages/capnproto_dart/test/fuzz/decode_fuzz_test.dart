// Mutation-based fuzz testing for the decode path.
//
// Takes a handful of validly-encoded seed messages and repeatedly applies
// random byte-level mutations (bit flips, truncation, insertion, byte-range
// duplication/zeroing/randomization) to them, then feeds the result through
// MessageReader.deserialize()/deserializePacked() and a full field read.
//
// A mutated message is allowed to do exactly one of two things:
//   1. Decode successfully (mutations can happen to land on bytes that don't
//      affect validity, or even produce another well-formed message), or
//   2. Throw a DecodeException.
// Anything else — an uncaught RangeError/StateError/other Dart runtime
// error, or a hang (guarded by this test's own timeout) — indicates a gap
// in the decoder's input validation and is reported as a failure, along
// with the exact mutated bytes needed to reproduce it.
//
// This is a lightweight, coverage-blind mutation fuzzer, not a true
// coverage-guided fuzzer (Dart has no libFuzzer/cargo-fuzz-equivalent
// tooling) — it trades thoroughness for being runnable as a normal `dart
// test` with no extra tooling, using a fixed random seed so failures are
// deterministic and reproducible in CI.

import 'dart:math';
import 'dart:typed_data';

import 'package:capnproto_dart/src/arena/arena_builder.dart';
import 'package:capnproto_dart/src/arena/arena_reader.dart';
import 'package:capnproto_dart/src/exception/decode_exception.dart';
import 'package:capnproto_dart/src/layout/list_builder.dart';
import 'package:capnproto_dart/src/layout/list_reader.dart';
import 'package:capnproto_dart/src/layout/struct_builder.dart';
import 'package:capnproto_dart/src/layout/struct_factory.dart';
import 'package:capnproto_dart/src/layout/struct_reader.dart';
import 'package:capnproto_dart/src/message/message_builder.dart';
import 'package:capnproto_dart/src/message/message_reader.dart';
import 'package:capnproto_dart/src/stream/packed_codec.dart';
import 'package:test/test.dart';

const _mutationsPerSeed = 3000;
const _fixedRandomSeed = 1337;

// ---------------------------------------------------------------------------
// Hand-written reader/builder/factory trio simulating generated code for:
//
//   struct Point { x @0 :Int32; y @1 :Int32; }
//
//   struct Widget {
//     flag @0 :Bool;
//     count @1 :Int32;
//     total @2 :Int64;
//     ratio @3 :Float64;
//     name @4 :Text;
//     tags @5 :List(Int32);
//     origin @6 :Point;
//   }
// ---------------------------------------------------------------------------

final class PointReader extends StructReader {
  PointReader(super.raw);
  int get x => getInt32Field(0);
  int get y => getInt32Field(4);
}

final class PointBuilder extends StructBuilder {
  PointBuilder(super.raw);
  set x(int v) => setInt32Field(0, v);
  set y(int v) => setInt32Field(4, v);

  @override
  PointReader asReader() => throw UnimplementedError();
}

final class _PointFactory extends StructFactory<PointReader, PointBuilder> {
  @override
  int get dataWords => 1;
  @override
  int get ptrWords => 0;
  @override
  PointReader fromRawReader(RawStructReader raw) => PointReader(raw);
  @override
  PointBuilder fromRawBuilder(RawStructBuilder raw) => PointBuilder(raw);
}

final pointFactory = _PointFactory();

final class WidgetReader extends StructReader {
  WidgetReader(super.raw);
  bool get flag => getBoolField(0);
  int get count => getInt32Field(4);
  int get total => getInt64Field(8);
  double get ratio => getFloat64Field(16);
  String? get name => getTextField(0);
  ListReader<int>? get tags => getInt32ListField(1);
  PointReader? get origin => getStructFieldWith(2, (r) => PointReader(r));
}

final class WidgetBuilder extends StructBuilder {
  WidgetBuilder(super.raw);
  set flag(bool v) => setBoolField(0, v);
  set count(int v) => setInt32Field(4, v);
  set total(int v) => setInt64Field(8, v);
  set ratio(double v) => setFloat64Field(16, v);
  set name(String? v) => setTextField(0, v);

  ListBuilder<int> initTags(int length) => initInt32ListField(1, length);

  PointBuilder initOrigin() =>
      initStructFieldWith(2, (r) => PointBuilder(r), 1, 0);

  @override
  WidgetReader asReader() => throw UnimplementedError();
}

final class _WidgetFactory extends StructFactory<WidgetReader, WidgetBuilder> {
  @override
  int get dataWords => 3;
  @override
  int get ptrWords => 3;
  @override
  WidgetReader fromRawReader(RawStructReader raw) => WidgetReader(raw);
  @override
  WidgetBuilder fromRawBuilder(RawStructBuilder raw) => WidgetBuilder(raw);
}

final widgetFactory = _WidgetFactory();

/// Fully traverses every field of [w], forcing lazy pointer/list/text
/// decoding to actually happen (a struct pointer alone doesn't validate its
/// contents until something reads into them).
void _touchAllFields(WidgetReader w) {
  var acc = 0;
  if (w.flag) acc += 1;
  acc += w.count;
  acc += w.total.remainder(97);
  acc += w.ratio.isFinite ? w.ratio.round() : 0;
  acc += w.name?.length ?? 0;
  for (final tag in w.tags ?? const <int>[]) {
    acc += tag;
  }
  final origin = w.origin;
  if (origin != null) {
    acc += origin.x + origin.y;
  }
  // Nothing reads `acc` back out — its only purpose is to force every
  // getter above to actually run instead of being dead-code-eliminated.
  if (acc == -0x7fffffffffffffff) {
    throw StateError('unreachable');
  }
}

Uint8List _buildSeed({
  required bool withText,
  required int tagCount,
  required bool withOrigin,
}) {
  final message = MessageBuilder();
  final widget = message.initRoot(widgetFactory);
  widget.flag = true;
  widget.count = 42;
  widget.total = 123456789012345;
  widget.ratio = 3.5;
  if (withText) widget.name = 'seed message';
  if (tagCount > 0) {
    final tags = widget.initTags(tagCount);
    for (var i = 0; i < tagCount; i++) {
      tags[i] = i * 7;
    }
  }
  if (withOrigin) {
    final origin = widget.initOrigin();
    origin.x = 10;
    origin.y = -20;
  }
  return message.serialize();
}

/// One randomized byte-level mutation, applied to a copy of [input].
Uint8List _mutate(Uint8List input, Random rng) {
  if (input.isEmpty) return Uint8List(0);
  final strategy = rng.nextInt(6);
  switch (strategy) {
    case 0: // flip a single random bit
      final out = Uint8List.fromList(input);
      final byteIndex = rng.nextInt(out.length);
      final bit = 1 << rng.nextInt(8);
      out[byteIndex] ^= bit;
      return out;
    case 1: // overwrite a single random byte
      final out = Uint8List.fromList(input);
      out[rng.nextInt(out.length)] = rng.nextInt(256);
      return out;
    case 2: // truncate to a random shorter length (possibly empty)
      final newLength = rng.nextInt(input.length + 1);
      return Uint8List.sublistView(input, 0, newLength);
    case 3: // insert random bytes at a random position
      final insertAt = rng.nextInt(input.length + 1);
      final insertLength = 1 + rng.nextInt(16);
      final out = Uint8List(input.length + insertLength);
      out.setRange(0, insertAt, input);
      for (var i = 0; i < insertLength; i++) {
        out[insertAt + i] = rng.nextInt(256);
      }
      out.setRange(insertAt + insertLength, out.length, input, insertAt);
      return out;
    case 4: // duplicate a random byte range, inserted right after itself
      final start = rng.nextInt(input.length);
      final length = 1 + rng.nextInt(input.length - start);
      final out = Uint8List(input.length + length);
      out.setRange(0, start + length, input);
      out.setRange(start + length, start + 2 * length, input, start);
      out.setRange(start + 2 * length, out.length, input, start + length);
      return out;
    case 5: // zero out a random byte range
    default:
      final out = Uint8List.fromList(input);
      final start = rng.nextInt(out.length);
      final length = 1 + rng.nextInt(out.length - start);
      out.fillRange(start, start + length, 0);
      return out;
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void _fuzzSeed(String seedName, Uint8List seed, {required bool packed}) {
  final rng = Random(_fixedRandomSeed);
  for (var i = 0; i < _mutationsPerSeed; i++) {
    final mutated = _mutate(seed, rng);
    try {
      final reader = packed
          ? MessageReader.deserializePacked(mutated)
          : MessageReader.deserialize(mutated);
      _touchAllFields(reader.getRoot(widgetFactory));
    } on DecodeException {
      // Expected outcome for malformed input — decoder correctly rejected it.
    } catch (e, st) {
      fail(
        'Seed "$seedName" (packed=$packed), mutation #$i produced an '
        'unhandled ${e.runtimeType} instead of a DecodeException.\n'
        'Error: $e\n'
        'Mutated bytes (hex): ${_hex(mutated)}\n'
        'Original seed (hex): ${_hex(seed)}\n'
        'Stack trace:\n$st',
      );
    }
  }
}

void main() {
  final seeds = <String, Uint8List>{
    'full (text + list + nested struct)': _buildSeed(
      withText: true,
      tagCount: 5,
      withOrigin: true,
    ),
    'empty (all default)': _buildSeed(
      withText: false,
      tagCount: 0,
      withOrigin: false,
    ),
    'long list (crosses multiple words)': _buildSeed(
      withText: true,
      tagCount: 200,
      withOrigin: true,
    ),
  };

  group('decode fuzz (unpacked)', () {
    for (final entry in seeds.entries) {
      test(
        entry.key,
        () => _fuzzSeed(entry.key, entry.value, packed: false),
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }
  });

  group('decode fuzz (packed)', () {
    for (final entry in seeds.entries) {
      final packedSeed = packBytes(entry.value);
      test(
        entry.key,
        () => _fuzzSeed(entry.key, packedSeed, packed: true),
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }
  });
}
