import 'dart:io';

import 'package:capnpc_dart/capnpc_dart.dart';

void main(List<String> args) async {
  // Normal mode: capnp invokes us as `capnpc-dart` via `-o dart:<dir>`
  // (stdin = CodeGeneratorRequest binary).
  //
  // Check mode: capnp's `-o` syntax has no channel for freeform plugin
  // options, so this is invoked directly instead of through `capnp compile
  // -o`: `capnp compile -o- new.capnp | capnpc-dart --check=old.capnp`.
  final checkFile = parseCheckFileArg(args);

  final bytes = await _readStdin();
  if (bytes.isEmpty) {
    stderr.writeln('capnpc-dart: no input on stdin');
    exitCode = 1;
    return;
  }

  try {
    final newReq = readSchemaRequest(bytes);

    if (checkFile != null) {
      await _runCheckMode(checkFile, newReq);
      return;
    }

    final results = generateDartFiles(newReq);
    for (final entry in results.entries) {
      final file = File(entry.key);
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
  } on Exception catch (e) {
    stderr.writeln('capnpc-dart: $e');
    exitCode = 2;
  }
}

Future<void> _runCheckMode(
    String oldCapnpPath, CodeGeneratorRequest newReq) async {
  try {
    final oldReq = await captureOldSchema(oldCapnpPath);
    final errors = checkCompatibility(oldReq, newReq);

    if (errors.isEmpty) {
      stdout.writeln('No incompatible changes detected.');
      exitCode = 0;
    } else {
      for (final e in errors) {
        stdout.writeln('INCOMPATIBLE: $e');
      }
      exitCode = 1;
    }
  } on Exception catch (e) {
    stderr.writeln('capnpc-dart: check mode error: $e');
    exitCode = 2;
  }
}

Future<List<int>> _readStdin() async {
  final bytes = <int>[];
  await for (final chunk in stdin) {
    bytes.addAll(chunk);
  }
  return bytes;
}
