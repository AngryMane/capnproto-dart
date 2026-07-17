import 'package:capnpc_dart/capnpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('parseCheckFileArg', () {
    test('extracts the path from --check=<path>', () {
      expect(parseCheckFileArg(['--check=old.capnp']), 'old.capnp');
    });

    test('finds --check among other args', () {
      expect(
        parseCheckFileArg(['--verbose', '--check=schema/old.capnp']),
        'schema/old.capnp',
      );
    });

    test('returns null when no --check flag is present', () {
      expect(parseCheckFileArg([]), isNull);
      expect(parseCheckFileArg(['--verbose']), isNull);
    });

    test('does not match the old, non-functional -o dart:check= syntax', () {
      // capnp's own `-o` plugin-selection syntax never actually delivers
      // this string as an argv element to the plugin (see codegen.dart) —
      // this test exists only to make sure a future edit doesn't silently
      // resurrect that dead code path as if it were real.
      expect(parseCheckFileArg(['-o dart:check=old.capnp']), isNull);
    });
  });
}
