import 'package:build/build.dart';
import 'package:capnpc_dart_builder/builder.dart';
import 'package:test/test.dart';

void main() {
  group('CapnpBuilder', () {
    test('declares .capnp -> .capnp.dart build extensions', () {
      final builder = capnpBuilder(BuilderOptions.empty);
      expect(builder.buildExtensions, {
        '.capnp': ['.capnp.dart'],
      });
    });
  });

  group('extractRelativeCapnpImports', () {
    test('extracts a single relative import', () {
      expect(
        extractRelativeCapnpImports('import "other.capnp";'),
        ['other.capnp'],
      );
    });

    test('extracts multiple imports across a schema', () {
      const source = '''
        @0xabcd;
        import "foo/bar.capnp";
        import "baz.capnp";

        struct S {}
      ''';
      expect(
        extractRelativeCapnpImports(source),
        ['foo/bar.capnp', 'baz.capnp'],
      );
    });

    test('ignores -I-rooted absolute imports', () {
      expect(
        extractRelativeCapnpImports('import "/capnp/c++.capnp";'),
        isEmpty,
      );
    });

    test('returns nothing for a schema with no imports', () {
      expect(extractRelativeCapnpImports('struct S {}'), isEmpty);
    });
  });

  group('CapnpCompileException', () {
    test('toString includes the input path and stderr', () {
      const exception = CapnpCompileException('foo.capnp', 'parse error');
      expect(exception.toString(), contains('foo.capnp'));
      expect(exception.toString(), contains('parse error'));
    });
  });
}
