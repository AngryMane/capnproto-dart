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
/// - An interface method (identified by its ordinal, i.e. wire method ID) was
///   removed, or its parameter/result struct gained an incompatible change
///   (by the same rules as any other struct).
///
/// **Safe changes (not flagged):**
/// - Adding new fields, enum variants, methods, or top-level types.
/// - Renaming fields, methods, or types (wire format uses ordinals/IDs, not
///   names).
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
        '(id=0x${nested.id.toRadixString(16)}) was removed',
      );
      continue;
    }

    if (oldNode.body.runtimeType != newNode.body.runtimeType) {
      errors.add(
        '"$name": kind changed from ${_kind(oldNode.body)} '
        'to ${_kind(newNode.body)}',
      );
      continue;
    }

    if (oldNode.body is StructBody) {
      _checkStruct(
        name,
        oldNode.body as StructBody,
        newNode.body as StructBody,
        errors,
      );
      // Recurse into nested types (e.g. groups declared inside the struct).
      _checkNestedNodes(oldNode, oldMap, newMap, errors);
    } else if (oldNode.body is EnumBody) {
      _checkEnum(
        name,
        oldNode.body as EnumBody,
        newNode.body as EnumBody,
        errors,
      );
    } else if (oldNode.body is InterfaceBody) {
      _checkInterface(
        name,
        oldNode.body as InterfaceBody,
        newNode.body as InterfaceBody,
        oldMap,
        newMap,
        errors,
      );
    }
  }
}

void _checkStruct(
  String name,
  StructBody oldBody,
  StructBody newBody,
  List<String> errors,
) {
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
      errors.add('$name.${oldField.name} (ordinal $ordinal) was removed');
      continue;
    }

    if (oldField.body is SlotField && newField.body is SlotField) {
      final os = oldField.body as SlotField;
      final ns = newField.body as SlotField;
      if (!_sameType(os.type, ns.type)) {
        errors.add(
          '$name.${oldField.name}: type changed from '
          '${_typeName(os.type)} to ${_typeName(ns.type)}',
        );
      }
      if (os.offset != ns.offset) {
        errors.add(
          '$name.${oldField.name}: wire offset changed from '
          '${os.offset} to ${ns.offset}',
        );
      }
    } else if (oldField.body.runtimeType != newField.body.runtimeType) {
      errors.add(
        '$name.${oldField.name}: field kind changed '
        '(${_fieldKind(oldField)} → ${_fieldKind(newField)})',
      );
    }
  }
}

void _checkEnum(
  String name,
  EnumBody oldBody,
  EnumBody newBody,
  List<String> errors,
) {
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

void _checkInterface(
  String name,
  InterfaceBody oldBody,
  InterfaceBody newBody,
  Map<int, SchemaNode> oldMap,
  Map<int, SchemaNode> newMap,
  List<String> errors,
) {
  // Match by ordinal (the method's position in the interface's method list,
  // which — unlike struct fields — is always the wire method ID; Cap'n Proto
  // gives interface methods no separate reorderable `@N` annotation distinct
  // from that position), not by name — matching by name would miss a
  // reordered/renumbered method's wire-level identity, and flagging a pure
  // rename would misreport a safe change as breaking.
  final oldByOrdinal = {for (final m in oldBody.methods) m.ordinal: m};
  final newByOrdinal = {for (final m in newBody.methods) m.ordinal: m};

  for (final entry in oldByOrdinal.entries) {
    final ordinal = entry.key;
    final oldMethod = entry.value;
    final newMethod = newByOrdinal[ordinal];

    if (newMethod == null) {
      errors.add('$name.${oldMethod.name} (ordinal $ordinal) was removed');
      continue;
    }

    _checkMethodStruct(
      '$name.${oldMethod.name} params',
      oldMethod.paramStructTypeId,
      newMethod.paramStructTypeId,
      oldMap,
      newMap,
      errors,
    );
    _checkMethodStruct(
      '$name.${oldMethod.name} results',
      oldMethod.resultStructTypeId,
      newMethod.resultStructTypeId,
      oldMap,
      newMap,
      errors,
    );
  }
}

/// Resolves [oldTypeId]/[newTypeId] (a method's implicit parameter or result
/// struct) and runs the normal struct compatibility check on them.
///
/// Diffing the resolved structs' fields — rather than just comparing
/// [oldTypeId] == [newTypeId] — both catches a parameter/result type change
/// that keeps the same auto-generated struct ID (e.g. retyping a parameter
/// in place) and avoids a false positive if the ID changed but the layout
/// didn't (which is wire-compatible regardless of the ID).
void _checkMethodStruct(
  String label,
  int oldTypeId,
  int newTypeId,
  Map<int, SchemaNode> oldMap,
  Map<int, SchemaNode> newMap,
  List<String> errors,
) {
  final oldStruct = oldMap[oldTypeId]?.body;
  final newStruct = newMap[newTypeId]?.body;
  if (oldStruct is! StructBody) {
    errors.add('$label: old parameter/result struct could not be resolved');
    return;
  }
  if (newStruct is! StructBody) {
    errors.add('$label: new parameter/result struct could not be resolved');
    return;
  }
  _checkStruct(label, oldStruct, newStruct, errors);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

bool _sameType(SchemaType a, SchemaType b) {
  if (a.runtimeType != b.runtimeType) return false;
  return switch (a) {
    ListType(:final elementType) => _sameType(
      elementType,
      (b as ListType).elementType,
    ),
    StructRefType(:final typeId) => typeId == (b as StructRefType).typeId,
    EnumRefType(:final typeId) => typeId == (b as EnumRefType).typeId,
    InterfaceRefType(:final typeId) => typeId == (b as InterfaceRefType).typeId,
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
  StructRefType(:final typeId) => 'Struct(0x${typeId.toRadixString(16)})',
  EnumRefType(:final typeId) => 'Enum(0x${typeId.toRadixString(16)})',
  InterfaceRefType(:final typeId) => 'Interface(0x${typeId.toRadixString(16)})',
  _ => 'Unknown',
};
