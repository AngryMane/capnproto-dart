import 'dart:io';
import 'dart:typed_data';

import '../schema/schema_model.dart';
import '../schema/schema_reader.dart';

/// Compiles [capnpFilePath] via the `capnp` binary and returns its
/// [CodeGeneratorRequest].
///
/// Throws a [CapnpLaunchException] if `capnp` could not be launched, or an
/// [Exception] if the file does not exist or compilation fails.
Future<CodeGeneratorRequest> captureOldSchema(String capnpFilePath) async {
  final tempDir = await Directory.systemTemp.createTemp('capnpc_dart_check_');
  try {
    return await _capture(capnpFilePath, tempDir);
  } finally {
    await tempDir.delete(recursive: true);
  }
}

Future<CodeGeneratorRequest> _capture(
    String capnpFilePath, Directory tempDir) async {
  final outputFile = File('${tempDir.path}/schema.bin');

  // A minimal shell script that acts as a capnp plugin: it reads the
  // CodeGeneratorRequest binary from stdin and writes it to outputFile.
  final captureScript = File('${tempDir.path}/capnpc-capture');
  await captureScript
      .writeAsString('#!/bin/sh\ncat > ${outputFile.path}\nexit 0\n');
  await Process.run('chmod', ['+x', captureScript.path]);

  final oldFile = File(capnpFilePath).absolute;
  if (!await oldFile.exists()) {
    throw Exception('Old schema file not found: $capnpFilePath');
  }
  final srcPrefix = oldFile.parent.path;

  // capnp invokes captureScript (absolute path) as the plugin.
  final ProcessResult result;
  try {
    result = await Process.run('capnp', [
      'compile',
      '--src-prefix=$srcPrefix',
      '-o',
      captureScript.path,
      oldFile.path,
    ]);
  } on ProcessException catch (e) {
    throw CapnpLaunchException(e);
  }

  if (result.exitCode != 0) {
    throw Exception(
        'capnp failed (exit ${result.exitCode}): ${result.stderr}');
  }

  if (!await outputFile.exists() || await outputFile.length() == 0) {
    throw Exception(
        'capnp produced no output for $capnpFilePath. '
        'Make sure the `capnp` compiler is installed and the schema is valid.');
  }

  final bytes = await outputFile.readAsBytes();
  return readCodeGeneratorRequest(Uint8List.fromList(bytes));
}

/// Thrown when the `capnp` subprocess couldn't be launched at all.
///
/// [cause] is the underlying [ProcessException] — most commonly because
/// `capnp` isn't installed or isn't on `PATH`, but it can also be a
/// permissions error or another OS-level launch failure, so this isn't
/// exclusively a "not installed" signal.
///
/// This package only shells out to the official `capnp` compiler — it does
/// not bundle or install it. Install it yourself (see
/// https://capnproto.org/install.html) and make sure it's on `PATH`.
class CapnpLaunchException implements Exception {
  /// The [ProcessException] raised when starting the `capnp` process failed.
  final ProcessException cause;

  const CapnpLaunchException(this.cause);

  @override
  String toString() =>
      'capnp could not be launched: ${cause.message}. This usually means '
      '`capnp` is not installed or not on PATH — install it yourself, see '
      'https://capnproto.org/install.html — but could also be a permissions '
      'or other OS-level launch failure. Underlying error: $cause';
}
