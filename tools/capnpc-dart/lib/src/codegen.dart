import 'dart:typed_data';

import 'generator/dart_generator.dart';
import 'schema/schema_model.dart';
import 'schema/schema_reader.dart';

/// Parses a raw [CodeGeneratorRequest] binary (Cap'n Proto framing) from stdin.
CodeGeneratorRequest readSchemaRequest(List<int> bytes) =>
    readCodeGeneratorRequest(Uint8List.fromList(bytes));

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
    final outputPath = _outputPath(inputPath);
    result[outputPath] = generateDartFile(fileNode, request.nodes);
  }

  return result;
}

/// Converts a `.capnp` input path to a `.capnp.dart` output path.
String _outputPath(String input) {
  if (input.endsWith('.capnp')) {
    return '${input.substring(0, input.length - 6)}.capnp.dart';
  }
  return '$input.dart';
}
