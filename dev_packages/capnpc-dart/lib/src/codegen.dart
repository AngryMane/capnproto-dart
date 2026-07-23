import 'dart:typed_data';

import 'generator/dart_generator.dart';
import 'schema/schema_model.dart';
import 'schema/schema_reader.dart';

/// Parses a raw [CodeGeneratorRequest] binary (Cap'n Proto framing) from stdin.
CodeGeneratorRequest readSchemaRequest(List<int> bytes) =>
    readCodeGeneratorRequest(Uint8List.fromList(bytes));

/// Parses the `--check=<path>` CLI flag that switches capnpc-dart into
/// schema compatibility-check mode (see doc/external-spec.md).
///
/// capnp's own `-o<lang>[:<dir>]` plugin-selection syntax always treats
/// everything after the first colon as an output directory — there is no
/// channel for a plugin to receive freeform options through it. So this mode
/// is invoked by dumping the request with `capnp compile -o-` and piping it
/// directly into the plugin binary, which is then free to accept ordinary
/// argv flags:
///
///   capnp compile -o- new.capnp | capnpc-dart --check=old.capnp
///
/// Returns null if no `--check` flag is present.
String? parseCheckFileArg(List<String> args) {
  const prefix = '--check=';
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      return arg.substring(prefix.length);
    }
  }
  return null;
}

/// Generates Dart source files for all requested files in [request].
///
/// Returns a map from output file path to file content.
Map<String, String> generateDartFiles(CodeGeneratorRequest request) {
  final nodeMap = {for (final n in request.nodes) n.id: n};
  final result = <String, String>{};

  for (final rf in request.requestedFiles) {
    final fileNode = nodeMap[rf.id];
    if (fileNode == null) continue;

    final inputPath = rf.filename;
    final outputPath = capnpToDartOutputPath(inputPath);
    result[outputPath] = generateDartFile(fileNode, request.nodes);
  }

  return result;
}
