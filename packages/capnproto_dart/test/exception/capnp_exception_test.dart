import 'package:capnproto_dart/capnproto_dart.dart';
// Not re-exported from the package barrel today (pre-existing, unrelated to
// #50 — SchemaException has no current callers anywhere in this repo), so
// it's imported directly here rather than via package:capnproto_dart.
import 'package:capnproto_dart/src/exception/schema_exception.dart';
import 'package:test/test.dart';

void main() {
  group('CapnpException — kind/cause (#50)', () {
    test('kind defaults to failed when not specified', () {
      const e = CapnpException('boom');
      expect(e.kind, ErrorKind.failed);
      expect(e.cause, isNull);
    });

    test('kind and cause can be set explicitly', () {
      final original = StateError('root cause');
      final e = CapnpException(
        'wrapped',
        kind: ErrorKind.disconnected,
        cause: original,
      );
      expect(e.kind, ErrorKind.disconnected);
      expect(e.cause, same(original));
    });

    test('toString omits the cause clause when there is no cause', () {
      const e = CapnpException('boom');
      expect(e.toString(), 'CapnpException: boom');
    });

    test('toString includes the cause when present', () {
      final e = CapnpException('wrapped', cause: 'root cause');
      expect(e.toString(), contains('wrapped'));
      expect(e.toString(), contains('caused by: root cause'));
    });
  });

  group('DecodeException — kind/cause passthrough (#50)', () {
    test('existing no-kind call sites keep defaulting to failed', () {
      const e = DecodeException('bad bytes');
      expect(e.kind, ErrorKind.failed);
      expect(e.toString(), 'DecodeException: bad bytes');
    });

    test('kind/cause are settable and appear in toString', () {
      final e = DecodeException(
        'bad bytes',
        kind: ErrorKind.overloaded,
        cause: 'inner',
      );
      expect(e.kind, ErrorKind.overloaded);
      expect(e.toString(), contains('DecodeException: bad bytes'));
      expect(e.toString(), contains('caused by: inner'));
    });
  });

  group('SchemaException — kind/cause passthrough (#50)', () {
    test('existing no-kind call sites keep defaulting to failed', () {
      const e = SchemaException('bad schema');
      expect(e.kind, ErrorKind.failed);
      expect(e.toString(), 'SchemaException: bad schema');
    });

    test('kind/cause are settable and appear in toString', () {
      final e = SchemaException(
        'bad schema',
        kind: ErrorKind.unimplemented,
        cause: 'inner',
      );
      expect(e.kind, ErrorKind.unimplemented);
      expect(e.toString(), contains('SchemaException: bad schema'));
      expect(e.toString(), contains('caused by: inner'));
    });
  });
}
