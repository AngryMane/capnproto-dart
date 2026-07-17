import 'package:capnpc_dart/capnpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers: build minimal CodeGeneratorRequest objects in memory.
// ---------------------------------------------------------------------------

const _fileId = 1;
const _structId = 100;
const _enumId = 200;

/// Builds a [CodeGeneratorRequest] with a single file node that contains
/// the given top-level [nodes].
CodeGeneratorRequest _req(List<SchemaNode> topLevel) {
  final fileNode = SchemaNode(
    id: _fileId,
    displayName: 'test.capnp',
    displayNamePrefixLength: 0,
    scopeId: 0,
    nestedNodes: [
      for (final n in topLevel) SchemaNestedNode(name: n.shortName, id: n.id),
    ],
    body: const FileBody(),
  );

  return CodeGeneratorRequest(
    nodes: [fileNode, ...topLevel],
    requestedFiles: [const RequestedFile(id: _fileId, filename: 'test.capnp')],
  );
}

SchemaNode _struct(List<SchemaField> fields) => SchemaNode(
      id: _structId,
      displayName: 'MyStruct',
      displayNamePrefixLength: 0,
      scopeId: _fileId,
      nestedNodes: const [],
      body: StructBody(
        dataWordCount: 1,
        pointerCount: 1,
        isGroup: false,
        discriminantCount: 0,
        discriminantOffset: 0,
        fields: fields,
      ),
    );

SchemaNode _enum(List<SchemaEnumerant> enumerants) => SchemaNode(
      id: _enumId,
      displayName: 'MyEnum',
      displayNamePrefixLength: 0,
      scopeId: _fileId,
      nestedNodes: const [],
      body: EnumBody(enumerants: enumerants),
    );

SchemaField _slotField(String name, int codeOrder, SchemaType type,
        {int offset = 0, int? ordinal}) =>
    SchemaField(
      name: name,
      codeOrder: codeOrder,
      // Defaults to codeOrder so existing callers that don't care about the
      // codeOrder-vs-ordinal distinction are unaffected; tests that
      // specifically exercise that distinction pass ordinal explicitly.
      ordinal: ordinal ?? codeOrder,
      discriminantValue: 0xFFFF,
      body: SlotField(offset: offset, type: type, hadExplicitDefault: false),
    );

SchemaEnumerant _enumerant(String name, int codeOrder) =>
    SchemaEnumerant(name: name, codeOrder: codeOrder);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('checkCompatibility — compatible changes', () {
    test('identical schemas produce no errors', () {
      final req = _req([
        _struct([_slotField('x', 0, const UInt32Type())]),
      ]);
      expect(checkCompatibility(req, req), isEmpty);
    });

    test('adding a new field is compatible', () {
      final old = _req([
        _struct([_slotField('x', 0, const UInt32Type())]),
      ]);
      final newReq = _req([
        _struct([
          _slotField('x', 0, const UInt32Type()),
          _slotField('y', 1, const UInt32Type(), offset: 1),
        ]),
      ]);
      expect(checkCompatibility(old, newReq), isEmpty);
    });

    test('adding a new enum variant is compatible', () {
      final old = _req([
        _enum([_enumerant('a', 0), _enumerant('b', 1)]),
      ]);
      final newReq = _req([
        _enum([_enumerant('a', 0), _enumerant('b', 1), _enumerant('c', 2)]),
      ]);
      expect(checkCompatibility(old, newReq), isEmpty);
    });

    test('renaming a field is compatible (wire format uses ordinals)', () {
      final old = _req([
        _struct([_slotField('oldName', 0, const UInt32Type())]),
      ]);
      final newReq = _req([
        _struct([_slotField('newName', 0, const UInt32Type())]),
      ]);
      expect(checkCompatibility(old, newReq), isEmpty);
    });

    test(
      'reordering field declarations without changing @N ordinals is '
      'compatible',
      () {
        // Regression test: the checker must match fields by wire ordinal
        // (@N), not by codeOrder (textual declaration order). Here `a` and
        // `b` swap declaration order between old/new, but each keeps its own
        // @N (and therefore its own type/offset) — a no-op on the wire.
        final old = _req([
          _struct([
            _slotField('a', 0, const Int32Type(), offset: 0, ordinal: 0),
            _slotField('b', 1, const TextType(), offset: 0, ordinal: 1),
          ]),
        ]);
        final newReq = _req([
          _struct([
            _slotField('b', 0, const TextType(), offset: 0, ordinal: 1),
            _slotField('a', 1, const Int32Type(), offset: 0, ordinal: 0),
          ]),
        ]);
        expect(checkCompatibility(old, newReq), isEmpty);
      },
    );

    test(
      'changing a field\'s actual @N ordinal is detected even when '
      'codeOrder stays the same',
      () {
        // Complements the reordering test above: codeOrder alone must not
        // be treated as compatible either — a real ordinal change (which
        // does change the field's wire slot) has to still be caught.
        final old = _req([
          _struct([
            _slotField('a', 0, const Int32Type(), offset: 0, ordinal: 0),
          ]),
        ]);
        final newReq = _req([
          _struct([
            _slotField('a', 0, const Int32Type(), offset: 1, ordinal: 1),
          ]),
        ]);
        expect(
          checkCompatibility(old, newReq),
          contains('MyStruct.a (ordinal 0) was removed'),
        );
      },
    );

    test('empty struct with no fields produces no errors', () {
      final req = _req([
        _struct([]),
      ]);
      expect(checkCompatibility(req, req), isEmpty);
    });
  });

  group('checkCompatibility — incompatible changes', () {
    test('removing a struct field is incompatible', () {
      final old = _req([
        _struct([
          _slotField('x', 0, const UInt32Type()),
          _slotField('y', 1, const UInt32Type(), offset: 1),
        ]),
      ]);
      final newReq = _req([
        _struct([_slotField('x', 0, const UInt32Type())]),
      ]);
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('y'));
      expect(errors.first, contains('removed'));
    });

    test('changing a field type is incompatible', () {
      final old = _req([
        _struct([_slotField('x', 0, const UInt32Type())]),
      ]);
      final newReq = _req([
        _struct([_slotField('x', 0, const UInt64Type())]),
      ]);
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('x'));
      expect(errors.first, contains('type changed'));
    });

    test('changing a field wire offset is incompatible', () {
      final old = _req([
        _struct([_slotField('x', 0, const UInt32Type(), offset: 0)]),
      ]);
      final newReq = _req([
        _struct([_slotField('x', 0, const UInt32Type(), offset: 2)]),
      ]);
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('offset changed'));
    });

    test('removing an enum variant is incompatible', () {
      final old = _req([
        _enum([_enumerant('a', 0), _enumerant('b', 1)]),
      ]);
      final newReq = _req([
        _enum([_enumerant('a', 0)]),
      ]);
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('b'));
      expect(errors.first, contains('removed'));
    });

    test('removing a struct is incompatible', () {
      final old = _req([
        _struct([_slotField('x', 0, const UInt32Type())]),
      ]);
      // New request has no nodes (except the file node itself).
      final newFileNode = SchemaNode(
        id: _fileId,
        displayName: 'test.capnp',
        displayNamePrefixLength: 0,
        scopeId: 0,
        nestedNodes: const [],
        body: const FileBody(),
      );
      final newReq = CodeGeneratorRequest(
        nodes: [newFileNode],
        requestedFiles: [
          const RequestedFile(id: _fileId, filename: 'test.capnp'),
        ],
      );
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('removed'));
    });

    test('multiple incompatibilities are all reported', () {
      final old = _req([
        _struct([
          _slotField('a', 0, const UInt32Type()),
          _slotField('b', 1, const TextType()),
        ]),
      ]);
      final newReq = _req([
        _struct([
          _slotField('a', 0, const UInt64Type()), // type changed
          // b removed
        ]),
      ]);
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(2));
      expect(errors.any((e) => e.contains('a') && e.contains('type')), isTrue);
      expect(errors.any((e) => e.contains('b') && e.contains('removed')),
          isTrue);
    });
  });
}
