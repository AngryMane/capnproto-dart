// Cross-language schema-evolution runtime compat driver (Dart side).
//
// See test/interop/schema-evolution/README.md for the full picture. This binary
// only implements one language's half; ci/run-tests.sh interleaves it with
// the Rust binary (test/interop/schema-evolution/rust) so that messages written by
// one language's vN schema are read back by the other language's vM schema.
//
// Usage:
//   dart run bin/main.dart write-v1 <path>   # encode {id,name,color} via v1
//   dart run bin/main.dart read-v2  <path>   # decode via v2, verify new
//                                             # fields fall back to defaults
//   dart run bin/main.dart write-v2 <path>   # encode all v2 fields
//   dart run bin/main.dart read-v1  <path>   # decode via v1, verify old
//                                             # fields still round-trip and
//                                             # the new ones are silently
//                                             # ignored (not an error)

import 'dart:io';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../lib/generated/v1/widget.capnp.dart' as v1;
import '../lib/generated/v2/widget.capnp.dart' as v2;

const expectedId1 = 42;
const expectedName1 = 'Widget-A';
const expectedColor1 = 'red';

const expectedId2 = 99;
const expectedName2 = 'Widget-B';
const expectedColor2 = 'blue';
const expectedWeight2 = 3.5;
const expectedTags2 = ['shiny', 'new'];
final expectedStatus2 = v2.Status.discontinued;

void _check(String label, Object? got, Object? expected) {
  if (got != expected) {
    stderr.writeln('MISMATCH $label: got=$got expected=$expected');
    exit(1);
  }
  print('  ok: $label = $got');
}

void writeV1(String path) {
  final mb = MessageBuilder();
  final w = mb.initRoot(v1.widgetFactory);
  w.id = expectedId1;
  w.name = expectedName1;
  w.color = expectedColor1;
  File(path).writeAsBytesSync(mb.serialize());
  print('dart write-v1 -> $path');
}

void readV2(String path) {
  final bytes = File(path).readAsBytesSync();
  final r = MessageReader.deserialize(bytes).getRoot(v2.widgetFactory);
  print('dart read-v2 <- $path (message was written against v1)');
  _check('id', r.id, expectedId1);
  _check('name', r.name, expectedName1);
  _check('color', r.color, expectedColor1);
  // Fields absent from the v1-encoded message must resolve to v2's declared
  // defaults, not crash or return garbage.
  _check('weight (v2-only, defaulted)', r.weight, 1.0);
  _check('tags (v2-only, absent -> empty)', r.tags?.length ?? 0, 0);
  _check('status (v2-only, defaulted)', r.status, v2.Status.active);
}

void writeV2(String path) {
  final mb = MessageBuilder();
  final w = mb.initRoot(v2.widgetFactory);
  w.id = expectedId2;
  w.name = expectedName2;
  w.color = expectedColor2;
  w.weight = expectedWeight2;
  final tags = w.initTags(expectedTags2.length);
  for (var i = 0; i < expectedTags2.length; i++) {
    tags[i] = expectedTags2[i];
  }
  w.status = expectedStatus2;
  File(path).writeAsBytesSync(mb.serialize());
  print('dart write-v2 -> $path');
}

void readV1(String path) {
  final bytes = File(path).readAsBytesSync();
  final r = MessageReader.deserialize(bytes).getRoot(v1.widgetFactory);
  print('dart read-v1 <- $path (message was written against v2)');
  // v1 code has never heard of weight/tags/status; the point of this test is
  // that it doesn't need to — it must still read the fields it knows about
  // correctly and must not throw on the unknown trailing data/pointers.
  _check('id', r.id, expectedId2);
  _check('name', r.name, expectedName2);
  _check('color', r.color, expectedColor2);
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: main.dart <write-v1|read-v2|write-v2|read-v1> <path>');
    exit(2);
  }
  final mode = args[0];
  final path = args[1];
  switch (mode) {
    case 'write-v1':
      writeV1(path);
      break;
    case 'read-v2':
      readV2(path);
      break;
    case 'write-v2':
      writeV2(path);
      break;
    case 'read-v1':
      readV1(path);
      break;
    default:
      stderr.writeln('unknown mode: $mode');
      exit(2);
  }
}
