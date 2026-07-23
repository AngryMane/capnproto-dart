// Wire-format golden-test driver (Dart side).
//
// See test/interop/wire-format-golden/README.md (well — this comment, there's no
// separate README) for the full picture: ci/run-tests.sh uses the official
// `capnp` CLI as the oracle for wire-format correctness, independent of RPC.
//
//   Direction 1 (Dart encode -> capnp decode):
//     `encode-scalars`/`encode-nested` write a message this binary built, and
//     the caller runs `capnp decode --short` on it and diffs the result
//     against the same text produced by round-tripping an equivalent literal
//     through `capnp encode | capnp decode` — i.e. the official implementation
//     is asked "does this look the same as if I'd encoded it myself?".
//
//   Direction 2 (capnp encode -> Dart decode):
//     the caller runs `capnp encode` on a hand-written literal (kept in sync
//     with the expected* constants below) and `decode-scalars`/`decode-nested`
//     verify Dart reads back the exact same field values, exiting non-zero on
//     any mismatch.
//
//   Direction 3 (canonicalization):
//     `encode-sparse`/`encode-children`/`encode-scalars-sparse` build fixtures
//     that deliberately leave some fields at their default (zero/null) value,
//     and `canonicalize` reads a framed message and writes the raw bytes of
//     its `MessageReader.canonicalize()` — the caller diffs that,
//     byte-for-byte, against `capnp convert binary:canonical` run on the same
//     input, which is the official reference for what a canonical encoding
//     looks like.
//
// Usage:
//   dart run bin/main.dart encode-scalars <path>
//   dart run bin/main.dart decode-scalars <path>
//   dart run bin/main.dart encode-nested  <path>
//   dart run bin/main.dart decode-nested  <path>
//   dart run bin/main.dart encode-scalars-sparse <path>
//   dart run bin/main.dart encode-sparse  <path>
//   dart run bin/main.dart encode-children <path>
//   dart run bin/main.dart canonicalize <in-path> <out-path>

import 'dart:io';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../lib/generated/golden.capnp.dart';

// Kept in sync with the literals ci/run-tests.sh passes to `capnp encode`.
const expectedBoolean = true;
const expectedInt8 = -8;
const expectedInt16 = -1600;
const expectedInt32 = -320000;
const expectedInt64 = -6400000000;
const expectedUint8 = 8;
const expectedUint16 = 1600;
const expectedUint32 = 320000;
const expectedUint64 = 6400000000;
const expectedFloat32 = 1.25;
const expectedFloat64 = -2.5;
const expectedText = 'hello "world"';
final expectedData = Uint8List.fromList([
  0x00,
  0x01,
  0x02,
  0x03,
  0x7f,
  0x80,
  0xfe,
  0xff,
]);
const expectedColor = Color.green;

void _check(String label, Object? got, Object? expected) {
  if (got != expected) {
    stderr.writeln('MISMATCH $label: got=$got expected=$expected');
    exit(1);
  }
  print('  ok: $label = $got');
}

void _checkBytes(String label, Uint8List? got, Uint8List expected) {
  final match =
      got != null &&
      got.length == expected.length &&
      List.generate(got.length, (i) => got[i] == expected[i]).every((x) => x);
  if (!match) {
    stderr.writeln('MISMATCH $label: got=$got expected=$expected');
    exit(1);
  }
  print('  ok: $label = $got');
}

// Dart's List.== is identity-based, not element-wise, so list-typed fields
// need their own deep-equality check rather than going through [_check].
void _checkList<T>(String label, List<T>? got, List<T> expected) {
  final match =
      got != null &&
      got.length == expected.length &&
      List.generate(got.length, (i) => got[i] == expected[i]).every((x) => x);
  if (!match) {
    stderr.writeln('MISMATCH $label: got=$got expected=$expected');
    exit(1);
  }
  print('  ok: $label = $got');
}

void encodeScalars(String path) {
  final mb = MessageBuilder();
  final s = mb.initRoot(allScalarsFactory);
  s.boolean = expectedBoolean;
  s.int8Value = expectedInt8;
  s.int16Value = expectedInt16;
  s.int32Value = expectedInt32;
  s.int64Value = expectedInt64;
  s.uint8Value = expectedUint8;
  s.uint16Value = expectedUint16;
  s.uint32Value = expectedUint32;
  s.uint64Value = expectedUint64;
  s.float32Value = expectedFloat32;
  s.float64Value = expectedFloat64;
  s.textValue = expectedText;
  s.dataValue = expectedData;
  s.color = expectedColor;
  File(path).writeAsBytesSync(mb.serialize());
  print('dart encode-scalars -> $path');
}

void decodeScalars(String path) {
  final bytes = File(path).readAsBytesSync();
  final r = MessageReader.deserialize(bytes).getRoot(allScalarsFactory);
  print('dart decode-scalars <- $path (encoded by capnp CLI)');
  _check('boolean', r.boolean, expectedBoolean);
  _check('int8Value', r.int8Value, expectedInt8);
  _check('int16Value', r.int16Value, expectedInt16);
  _check('int32Value', r.int32Value, expectedInt32);
  _check('int64Value', r.int64Value, expectedInt64);
  _check('uint8Value', r.uint8Value, expectedUint8);
  _check('uint16Value', r.uint16Value, expectedUint16);
  _check('uint32Value', r.uint32Value, expectedUint32);
  _check('uint64Value', r.uint64Value, expectedUint64);
  _check('float32Value', r.float32Value, expectedFloat32);
  _check('float64Value', r.float64Value, expectedFloat64);
  _check('textValue', r.textValue, expectedText);
  _checkBytes('dataValue', r.dataValue, expectedData);
  _check('color', r.color, expectedColor);
}

void encodeNested(String path) {
  final mb = MessageBuilder();
  final root = mb.initRoot(nestedFactory);
  root.label = 'root';
  final values = root.initValues(3);
  values[0] = 1;
  values[1] = 2;
  values[2] = 3;
  final tags = root.initTags(2);
  tags[0] = 'a';
  tags[1] = 'b';
  final children = root.initChildren(2);
  children[0].label = 'child1';
  children[0].initValues(1)[0] = 4;
  children[0].initTags(0);
  children[0].initChildren(0);
  children[1].label = 'child2';
  children[1].initValues(0);
  children[1].initTags(1)[0] = 'x';
  children[1].initChildren(0);
  File(path).writeAsBytesSync(mb.serialize());
  print('dart encode-nested -> $path');
}

void decodeNested(String path) {
  final bytes = File(path).readAsBytesSync();
  final r = MessageReader.deserialize(bytes).getRoot(nestedFactory);
  print('dart decode-nested <- $path (encoded by capnp CLI)');
  _check('label', r.label, 'root');
  _checkList('values', r.values?.toList(), [1, 2, 3]);
  _checkList('tags', r.tags?.toList(), ['a', 'b']);
  final children = r.children;
  _check('children.length', children?.length, 2);
  _check('children[0].label', children?[0].label, 'child1');
  _checkList('children[0].values', children?[0].values?.toList(), [4]);
  _checkList('children[0].tags', children?[0].tags?.toList(), <String>[]);
  _check('children[1].label', children?[1].label, 'child2');
  _checkList('children[1].values', children?[1].values?.toList(), <int>[]);
  _checkList('children[1].tags', children?[1].tags?.toList(), ['x']);
}

// Only `boolean` is set; every other AllScalars field is left at its wire
// default (0 / false / empty). Canonicalizing this should trim the data
// section down to just the word holding `boolean`, since every field after
// it is a trailing default (per the wire layout, boolean is the first field
// and word-splits before the multi-byte fields, so this is not simply "field
// order == trim order" in general, but is a real trim capnp's canonicalizer
// performs — see the CI diff against `capnp convert binary:canonical`).
void encodeScalarsSparse(String path) {
  final mb = MessageBuilder();
  final s = mb.initRoot(allScalarsFactory);
  s.boolean = true;
  File(path).writeAsBytesSync(mb.serialize());
  print('dart encode-scalars-sparse -> $path');
}

// Only `label` is set; values/tags/children are never touched, so their
// pointer slots are genuinely null (not just empty lists). Canonicalizing
// should trim the struct's pointer section from 4 words down to 1.
void encodeSparse(String path) {
  final mb = MessageBuilder();
  final root = mb.initRoot(nestedFactory);
  root.label = 'root';
  File(path).writeAsBytesSync(mb.serialize());
  print('dart encode-sparse -> $path');
}

// A children list whose elements need different amounts of trimming:
// child[0] only sets `label` (needs 1 pointer word), child[1] also sets
// `values` (needs 2). Canonicalizing a list of structs must re-pack every
// element to the same, smallest-common size (max across elements: 2 pointer
// words here), not each element's own individual minimum.
void encodeChildren(String path) {
  final mb = MessageBuilder();
  final root = mb.initRoot(nestedFactory);
  root.label = 'root';
  final children = root.initChildren(2);
  children[0].label = 'only-label';
  children[1].label = 'with-values';
  children[1].initValues(1)[0] = 42;
  File(path).writeAsBytesSync(mb.serialize());
  print('dart encode-children -> $path');
}

void canonicalize(String inPath, String outPath) {
  final bytes = File(inPath).readAsBytesSync();
  final canonical = MessageReader.deserialize(bytes).canonicalize();
  File(outPath).writeAsBytesSync(canonical);
  print('dart canonicalize $inPath -> $outPath (${canonical.length} bytes)');
}

final _textRegistry = schemaRegistryOf([
  allScalarsSchema,
  colorSchema,
  nestedSchema,
]);

void encodeTextScalars() {
  final mb = MessageBuilder();
  final s = mb.initRoot(allScalarsFactory);
  s.boolean = expectedBoolean;
  s.int8Value = expectedInt8;
  s.int16Value = expectedInt16;
  s.int32Value = expectedInt32;
  s.int64Value = expectedInt64;
  s.uint8Value = expectedUint8;
  s.uint16Value = expectedUint16;
  s.uint32Value = expectedUint32;
  s.uint64Value = expectedUint64;
  s.float32Value = expectedFloat32;
  s.float64Value = expectedFloat64;
  s.textValue = expectedText;
  s.dataValue = expectedData;
  s.color = expectedColor;
  final reader = MessageReader.deserialize(
    mb.serialize(),
  ).getRoot(allScalarsFactory);
  stdout.write(encodeText(reader, allScalarsSchema, _textRegistry));
}

void encodeTextNested() {
  final mb = MessageBuilder();
  final root = mb.initRoot(nestedFactory);
  root.label = 'root';
  final values = root.initValues(3);
  values[0] = 1;
  values[1] = 2;
  values[2] = 3;
  final tags = root.initTags(2);
  tags[0] = 'a';
  tags[1] = 'b';
  final children = root.initChildren(2);
  children[0].label = 'child1';
  children[0].initValues(1)[0] = 4;
  children[0].initTags(0);
  children[0].initChildren(0);
  children[1].label = 'child2';
  children[1].initValues(0);
  children[1].initTags(1)[0] = 'x';
  children[1].initChildren(0);
  final reader = MessageReader.deserialize(
    mb.serialize(),
  ).getRoot(nestedFactory);
  stdout.write(encodeText(reader, nestedSchema, _textRegistry));
}

void decodeTextToFile(String path, StructSchemaInfo schema) {
  final text = stdin.readLineSync();
  if (text == null) {
    stderr.writeln('expected one text-format message on stdin');
    exit(2);
  }
  File(path).writeAsBytesSync(decodeText(text, schema, _textRegistry));
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: main.dart <mode> <path...>');
    exit(2);
  }
  final mode = args[0];
  switch (mode) {
    case 'encode-text-scalars':
      encodeTextScalars();
      break;
    case 'encode-text-nested':
      encodeTextNested();
      break;
    case 'decode-text-scalars':
      decodeTextToFile(args[1], allScalarsSchema);
      break;
    case 'decode-text-nested':
      decodeTextToFile(args[1], nestedSchema);
      break;
    case 'encode-scalars':
      encodeScalars(args[1]);
      break;
    case 'decode-scalars':
      decodeScalars(args[1]);
      break;
    case 'encode-nested':
      encodeNested(args[1]);
      break;
    case 'decode-nested':
      decodeNested(args[1]);
      break;
    case 'encode-scalars-sparse':
      encodeScalarsSparse(args[1]);
      break;
    case 'encode-sparse':
      encodeSparse(args[1]);
      break;
    case 'encode-children':
      encodeChildren(args[1]);
      break;
    case 'canonicalize':
      canonicalize(args[1], args[2]);
      break;
    default:
      stderr.writeln('unknown mode: $mode');
      exit(2);
  }
}
