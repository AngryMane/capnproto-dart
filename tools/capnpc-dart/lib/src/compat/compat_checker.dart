import '../schema/schema_model.dart';

/// Checks whether [newReq] is backward-compatible with [oldReq].
///
/// Returns a (possibly empty) list of human-readable descriptions of breaking
/// changes.  An empty list means the schemas are compatible.
///
/// **Breaking changes detected:**
/// - A struct, enum, or interface that existed in the old schema is absent from
///   the new schema (identified by its 64-bit node ID).
/// - A struct field (identified by its declaration ordinal) was removed or had
///   its type or wire offset changed.
/// - An enum enumerant (identified by its declaration index) was removed.
///
/// **Safe changes (not flagged):**
/// - Adding new fields, enum variants, or top-level types.
/// - Renaming fields or types (wire format uses ordinals/IDs, not names).
List<String> checkCompatibility(
  CodeGeneratorRequest oldReq,
  CodeGeneratorRequest newReq,
) {
  final errors = <String>[];
  final oldMap = {for (final n in oldReq.nodes) n.id: n};
  final newMap = {for (final n in newReq.nodes) n.id: n};

  for (final rf in oldReq.requestedFiles) {
    final fileNode = oldMap[rf.id];
    if (fileNode == null) continue;
    _checkNestedNodes(fileNode, oldMap, newMap, errors);
  }

  return errors;
}

void _checkNestedNodes(
  SchemaNode parent,
  Map<int, SchemaNode> oldMap,
  Map<int, SchemaNode> newMap,
  List<String> errors,
) {
  for (final nested in parent.nestedNodes) {
    final oldNode = oldMap[nested.id];
    if (oldNode == null) continue;

    final name = oldNode.shortName;
    final newNode = newMap[nested.id];

    if (newNode == null) {
      errors.add(
          '${_kind(oldNode.body)} "$name" '
          '(id=0x${nested.id.toRadixString(16)}) was removed');
      continue;
    }

    if (oldNode.body.runtimeType != newNode.body.runtimeType) {
      errors.add('"$name": kind changed from ${_kind(oldNode.body)} '
          'to ${_kind(newNode.body)}');
      continue;
    }

    if (oldNode.body is StructBody) {
      _checkStruct(
          name, oldNode.body as StructBody, newNode.body as StructBody, errors);
      // Recurse into nested types (e.g. groups declared inside the struct).
      _checkNestedNodes(oldNode, oldMap, newMap, errors);
    } else if (oldNode.body is EnumBody) {
      _checkEnum(
          name, oldNode.body as EnumBody, newNode.body as EnumBody, errors);
    }
  }
}

void _checkStruct(
    String name, StructBody oldBody, StructBody newBody, List<String> errors) {
  // Match by wire ordinal (the `@N` that actually governs slot allocation),
  // not codeOrder (textual declaration order) — two schema versions can
  // legally reorder field declarations without touching any `@N`, and that
  // must not be reported as every reordered field's type/offset changing.
  final oldByOrdinal = {for (final f in oldBody.fields) f.ordinal: f};
  final newByOrdinal = {for (final f in newBody.fields) f.ordinal: f};

  for (final entry in oldByOrdinal.entries) {
    final ordinal = entry.key;
    final oldField = entry.value;
    final newField = newByOrdinal[ordinal];

    if (newField == null) {
      errors
          .add('$name.${oldField.name} (ordinal $ordinal) was removed');
      continue;
    }

    if (oldField.body is SlotField && newField.body is SlotField) {
      final os = oldField.body as SlotField;
      final ns = newField.body as SlotField;
      if (!_sameType(os.type, ns.type)) {
        errors.add('$name.${oldField.name}: type changed from '
            '${_typeName(os.type)} to ${_typeName(ns.type)}');
      }
      if (os.offset != ns.offset) {
        errors.add('$name.${oldField.name}: wire offset changed from '
            '${os.offset} to ${ns.offset}');
      }
    } else if (oldField.body.runtimeType != newField.body.runtimeType) {
      errors.add('$name.${oldField.name}: field kind changed '
          '(${_fieldKind(oldField)} → ${_fieldKind(newField)})');
    }
  }
}

void _checkEnum(
    String name, EnumBody oldBody, EnumBody newBody, List<String> errors) {
  final oldByIndex = {for (final e in oldBody.enumerants) e.codeOrder: e};
  final newByIndex = {for (final e in newBody.enumerants) e.codeOrder: e};

  for (final entry in oldByIndex.entries) {
    final idx = entry.key;
    final oldE = entry.value;
    if (!newByIndex.containsKey(idx)) {
      errors.add('$name.${oldE.name} (index $idx) was removed');
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

bool _sameType(SchemaType a, SchemaType b) {
  if (a.runtimeType != b.runtimeType) return false;
  return switch (a) {
    ListType(:final elementType) =>
      _sameType(elementType, (b as ListType).elementType),
    StructRefType(:final typeId) => typeId == (b as StructRefType).typeId,
    EnumRefType(:final typeId) => typeId == (b as EnumRefType).typeId,
    InterfaceRefType(:final typeId) =>
      typeId == (b as InterfaceRefType).typeId,
    _ => true,
  };
}

String _kind(SchemaNodeBody body) => switch (body) {
      StructBody() => 'struct',
      EnumBody() => 'enum',
      InterfaceBody() => 'interface',
      ConstBody() => 'const',
      AnnotationBody() => 'annotation',
      _ => 'file',
    };

String _fieldKind(SchemaField f) => f.body is SlotField ? 'slot' : 'group';

String _typeName(SchemaType t) => switch (t) {
      VoidType() => 'Void',
      BoolType() => 'Bool',
      Int8Type() => 'Int8',
      Int16Type() => 'Int16',
      Int32Type() => 'Int32',
      Int64Type() => 'Int64',
      UInt8Type() => 'UInt8',
      UInt16Type() => 'UInt16',
      UInt32Type() => 'UInt32',
      UInt64Type() => 'UInt64',
      Float32Type() => 'Float32',
      Float64Type() => 'Float64',
      TextType() => 'Text',
      DataType() => 'Data',
      AnyPointerType() => 'AnyPointer',
      ListType(:final elementType) => 'List(${_typeName(elementType)})',
      StructRefType(:final typeId) =>
        'Struct(0x${typeId.toRadixString(16)})',
      EnumRefType(:final typeId) => 'Enum(0x${typeId.toRadixString(16)})',
      InterfaceRefType(:final typeId) =>
        'Interface(0x${typeId.toRadixString(16)})',
      _ => 'Unknown',
    };
