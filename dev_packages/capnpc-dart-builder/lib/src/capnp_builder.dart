import 'dart:async';
import 'dart:io';

import 'package:build/build.dart';
import 'package:capnpc_dart/capnpc_dart.dart';
import 'package:path/path.dart' as p;

/// A [Builder] that generates `.capnp.dart` from `.capnp` schema files by
/// shelling out to the official `capnp` CLI (`capnp compile -o-`) and
/// feeding the resulting `CodeGeneratorRequest` to capnpc_dart's existing
/// generator — the same code path `capnp compile -o dart:...` uses, just
/// invoked from build_runner instead of capnp's own plugin mechanism.
///
/// `capnp` itself must be installed separately and be on `PATH`; this
/// package does not parse `.capnp` syntax, only capnp's compiled output.
///
/// Only supports schema files that live within the package being built and
/// import each other via ordinary relative paths — capnp's own `-I`-rooted
/// imports (e.g. reaching into another pub package's directory) aren't
/// resolved automatically. Pass extra search roots via the builder's
/// `import_paths` option in `build.yaml` if you need them:
///
/// ```yaml
/// targets:
///   $default:
///     builders:
///       capnpc_dart_builder|capnp:
///         options:
///           import_paths: ["../shared_schemas"]
/// ```
class CapnpBuilder implements Builder {
  final List<String> extraImportPaths;

  CapnpBuilder(BuilderOptions options)
    : extraImportPaths =
          (options.config['import_paths'] as List?)?.cast<String>() ??
          const [];

  @override
  Map<String, List<String>> get buildExtensions => {
    '.capnp': ['.capnp.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;
    final projectRoot = Directory.current.path;

    // Run with cwd = the schema file's own directory and a bare basename
    // argument, matching how these schemas are compiled outside build_runner
    // (`cd` into the schema's directory, then `capnp compile -o dart:. x.capnp`)
    // — capnp reports back whatever path we pass it, resolved against its own
    // cwd, and that reported name also becomes each node's `displayName` in
    // the generated reflection metadata. Passing `inputId.path` (e.g.
    // `lib/schema/complex.capnp`) directly would leak build_runner's internal
    // asset-path structure into `displayName` (e.g. `lib/schema/complex.capnp:Color`
    // instead of `complex.capnp:Color`).
    final schemaDir = p.dirname(p.join(projectRoot, inputId.path));
    final basename = p.basename(inputId.path);
    final result = await Process.run('capnp', [
      'compile',
      '-o-',
      for (final importPath in extraImportPaths)
        '-I${p.join(projectRoot, importPath)}',
      basename,
    ], workingDirectory: schemaDir, stdoutEncoding: null);

    if (result.exitCode != 0) {
      throw CapnpCompileException(inputId.path, result.stderr.toString());
    }

    final request = readSchemaRequest(result.stdout as List<int>);
    final outputs = generateDartFiles(request);

    final outputBasename = capnpToDartOutputPath(basename);
    final content = outputs[outputBasename];
    if (content == null) {
      // capnp's requestedFiles didn't include an entry matching inputId —
      // shouldn't happen for a well-formed single-file compile, but fail
      // loudly rather than silently emitting nothing.
      throw StateError(
        'capnp compile did not report "$basename" as a requested '
        'file (got: ${outputs.keys.join(', ')})',
      );
    }

    final outputPath = p.join(p.dirname(inputId.path), outputBasename);
    await buildStep.writeAsString(AssetId(inputId.package, outputPath), content);

    // Best-effort incremental-build dependency tracking: capnp resolves
    // `import "...";` statements itself, invisibly to build_runner, so
    // without this, editing an imported (but not directly-built) .capnp
    // file wouldn't trigger a rebuild of files that import it.
    await _trackImports(buildStep, inputId);
  }

  Future<void> _trackImports(BuildStep buildStep, AssetId inputId) async {
    final source = await buildStep.readAsString(inputId);
    for (final importPath in extractRelativeCapnpImports(source)) {
      final resolved = p.normalize(
        p.join(p.dirname(inputId.path), importPath),
      );
      final importedId = AssetId(inputId.package, resolved);
      if (await buildStep.canRead(importedId)) {
        // The read itself is what registers the dependency edge; the
        // content isn't used here (capnp re-reads the real file itself).
        await buildStep.readAsString(importedId);
      }
    }
  }
}

final RegExp _importPattern = RegExp(r'import\s+"([^"]+)"');

/// Extracts the paths of `import "...";` statements in [source] that are
/// package-relative (i.e. not a capnp `-I`-rooted absolute import like
/// `/capnp/c++.capnp`, which isn't a same-package asset build_runner can
/// track).
List<String> extractRelativeCapnpImports(String source) => [
  for (final match in _importPattern.allMatches(source))
    match.group(1)!,
].where((path) => !path.startsWith('/')).toList();

/// Thrown when the `capnp` subprocess exits non-zero — most commonly a
/// schema syntax error, or `capnp` not being installed/on PATH.
class CapnpCompileException implements Exception {
  final String inputPath;
  final String stderr;

  const CapnpCompileException(this.inputPath, this.stderr);

  @override
  String toString() =>
      'capnp compile failed for "$inputPath":\n$stderr';
}
