import 'package:capnpc_dart/capnpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers: build minimal CodeGeneratorRequest objects in memory.
// ---------------------------------------------------------------------------

const _fileId = 1;
const _structId = 100;
const _enumId = 200;
const _interfaceId = 300;

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

SchemaField _slotField(
  String name,
  int codeOrder,
  SchemaType type, {
  int offset = 0,
  int? ordinal,
}) => SchemaField(
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

SchemaMethod _method(
  String name,
  int ordinal,
  int paramStructTypeId,
  int resultStructTypeId,
) => SchemaMethod(
  name: name,
  ordinal: ordinal,
  paramStructTypeId: paramStructTypeId,
  resultStructTypeId: resultStructTypeId,
);

/// Builds a method's auto-generated parameter/result struct node. Real capnp
/// gives these their own top-level node (reachable only via
/// [SchemaMethod.paramStructTypeId]/[resultStructTypeId], not via any
/// interface's `nestedNodes`) — mirrored here so tests exercise exactly the
/// same shape [_checkMethodStruct] resolves against.
SchemaNode _methodStruct(int id, String name, List<SchemaField> fields) =>
    SchemaNode(
      id: id,
      displayName: name,
      displayNamePrefixLength: 0,
      scopeId: 0,
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

/// Builds a [CodeGeneratorRequest] with a single file node containing one
/// interface (with [methods]), plus [structNodes] (the methods' param/result
/// structs) as separate top-level nodes — not listed in the file's
/// `nestedNodes`, matching real capnp output.
CodeGeneratorRequest _interfaceReq(
  List<SchemaMethod> methods,
  List<SchemaNode> structNodes,
) {
  final interfaceNode = SchemaNode(
    id: _interfaceId,
    displayName: 'MyInterface',
    displayNamePrefixLength: 0,
    scopeId: _fileId,
    nestedNodes: const [],
    body: InterfaceBody(methods: methods),
  );
  final fileNode = SchemaNode(
    id: _fileId,
    displayName: 'test.capnp',
    displayNamePrefixLength: 0,
    scopeId: 0,
    nestedNodes: const [
      SchemaNestedNode(name: 'MyInterface', id: _interfaceId),
    ],
    body: const FileBody(),
  );
  return CodeGeneratorRequest(
    nodes: [fileNode, interfaceNode, ...structNodes],
    requestedFiles: [const RequestedFile(id: _fileId, filename: 'test.capnp')],
  );
}

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

    test('reordering field declarations without changing @N ordinals is '
        'compatible', () {
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
    });

    test('changing a field\'s actual @N ordinal is detected even when '
        'codeOrder stays the same', () {
      // Complements the reordering test above: codeOrder alone must not
      // be treated as compatible either — a real ordinal change (which
      // does change the field's wire slot) has to still be caught.
      final old = _req([
        _struct([_slotField('a', 0, const Int32Type(), offset: 0, ordinal: 0)]),
      ]);
      final newReq = _req([
        _struct([_slotField('a', 0, const Int32Type(), offset: 1, ordinal: 1)]),
      ]);
      expect(
        checkCompatibility(old, newReq),
        contains('MyStruct.a (ordinal 0) was removed'),
      );
    });

    test('empty struct with no fields produces no errors', () {
      final req = _req([_struct([])]);
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
      expect(
        errors.any((e) => e.contains('b') && e.contains('removed')),
        isTrue,
      );
    });
  });

  group('checkCompatibility — interface methods (#55)', () {
    test('appending a new method is compatible', () {
      final fooParams = _methodStruct(1000, 'Foo\$Params', const []);
      final fooResults = _methodStruct(1001, 'Foo\$Results', const []);
      final barParams = _methodStruct(1002, 'Bar\$Params', const []);
      final barResults = _methodStruct(1003, 'Bar\$Results', const []);

      final old = _interfaceReq(
        [_method('foo', 0, 1000, 1001)],
        [fooParams, fooResults],
      );
      final newReq = _interfaceReq(
        [_method('foo', 0, 1000, 1001), _method('bar', 1, 1002, 1003)],
        [fooParams, fooResults, barParams, barResults],
      );
      expect(checkCompatibility(old, newReq), isEmpty);
    });

    test('renaming a method is compatible (wire format uses ordinals)', () {
      final params = _methodStruct(1000, 'Foo\$Params', const []);
      final results = _methodStruct(1001, 'Foo\$Results', const []);

      final old = _interfaceReq(
        [_method('oldName', 0, 1000, 1001)],
        [params, results],
      );
      final newReq = _interfaceReq(
        [_method('newName', 0, 1000, 1001)],
        [params, results],
      );
      expect(checkCompatibility(old, newReq), isEmpty);
    });

    test('removing an interface method is incompatible', () {
      final params = _methodStruct(1000, 'Foo\$Params', const []);
      final results = _methodStruct(1001, 'Foo\$Results', const []);

      final old = _interfaceReq(
        [_method('foo', 0, 1000, 1001)],
        [params, results],
      );
      final newReq = _interfaceReq(const [], const []);
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('foo'));
      expect(errors.first, contains('removed'));
    });

    test('changing a method parameter type is incompatible', () {
      final oldParams = _methodStruct(1000, 'Foo\$Params', [
        _slotField('x', 0, const UInt32Type()),
      ]);
      final results = _methodStruct(1001, 'Foo\$Results', const []);
      final newParams = _methodStruct(1000, 'Foo\$Params', [
        _slotField('x', 0, const TextType()),
      ]);

      final old = _interfaceReq(
        [_method('foo', 0, 1000, 1001)],
        [oldParams, results],
      );
      final newReq = _interfaceReq(
        [_method('foo', 0, 1000, 1001)],
        [newParams, results],
      );
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('foo params'));
      expect(errors.first, contains('type changed'));
    });

    test('removing a method parameter is incompatible', () {
      final oldParams = _methodStruct(1000, 'Foo\$Params', [
        _slotField('x', 0, const UInt32Type()),
        _slotField('y', 1, const UInt32Type(), offset: 1),
      ]);
      final results = _methodStruct(1001, 'Foo\$Results', const []);
      final newParams = _methodStruct(1000, 'Foo\$Params', [
        _slotField('x', 0, const UInt32Type()),
      ]);

      final old = _interfaceReq(
        [_method('foo', 0, 1000, 1001)],
        [oldParams, results],
      );
      final newReq = _interfaceReq(
        [_method('foo', 0, 1000, 1001)],
        [newParams, results],
      );
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('foo params'));
      expect(errors.first, contains('y'));
      expect(errors.first, contains('removed'));
    });

    test('changing a method result type is incompatible', () {
      final params = _methodStruct(1000, 'Foo\$Params', const []);
      final oldResults = _methodStruct(1001, 'Foo\$Results', [
        _slotField('reply', 0, const TextType()),
      ]);
      final newResults = _methodStruct(1001, 'Foo\$Results', [
        _slotField('reply', 0, const UInt32Type()),
      ]);

      final old = _interfaceReq(
        [_method('foo', 0, 1000, 1001)],
        [params, oldResults],
      );
      final newReq = _interfaceReq(
        [_method('foo', 0, 1000, 1001)],
        [params, newResults],
      );
      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('foo results'));
      expect(errors.first, contains('type changed'));
    });

    test('missing old method parameter struct is diagnosed', () {
      final results = _methodStruct(1001, 'Foo\$Results', const []);

      final old = _interfaceReq([_method('foo', 0, 1000, 1001)], [results]);
      final newReq = _interfaceReq([_method('foo', 0, 1000, 1001)], [results]);

      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('foo params'));
      expect(errors.first, contains('old parameter/result struct'));
    });

    test('missing new method result struct is diagnosed', () {
      final params = _methodStruct(1000, 'Foo\$Params', const []);
      final oldResults = _methodStruct(1001, 'Foo\$Results', const []);

      final old = _interfaceReq(
        [_method('foo', 0, 1000, 1001)],
        [params, oldResults],
      );
      final newReq = _interfaceReq([_method('foo', 0, 1000, 1001)], [params]);

      final errors = checkCompatibility(old, newReq);
      expect(errors, hasLength(1));
      expect(errors.first, contains('foo results'));
      expect(errors.first, contains('new parameter/result struct'));
    });
  });
}
