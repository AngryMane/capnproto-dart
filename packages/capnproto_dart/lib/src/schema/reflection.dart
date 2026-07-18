/// Lightweight schema reflection metadata emitted by `capnpc-dart`.
///
/// These classes intentionally model the information most useful at runtime:
/// node ids, names, struct layout, fields, enum values, and interface methods.
/// They are not a full in-memory representation of `schema.capnp`.
sealed class SchemaInfo {
  final int id;
  final String displayName;
  final String shortName;

  /// Annotations applied directly to this node (e.g. `$myAnno(...)` right
  /// after a `struct`/`enum`/`interface` declaration). Empty if none.
  final List<AnnotationInfo> annotations;

  const SchemaInfo({
    required this.id,
    required this.displayName,
    required this.shortName,
    this.annotations = const [],
  });
}

/// A single annotation application captured from the schema (e.g.
/// `$myAnno("hello")`), as emitted by `capnpc-dart`.
///
/// [id] is the declaring annotation node's id (the `annotation myAnno
/// @0x... (...) :T;` declaration is not itself represented at runtime —
/// look up its id in your own schema if you need its name or declared
/// value type). [value] uses the same representation as
/// [SlotFieldSchemaInfo.defaultValue]: `bool`/`int`/`double` for scalars,
/// `String` for Text, `Uint8List` for Data/List/Struct, or `null` for a
/// Void-valued annotation.
final class AnnotationInfo {
  final int id;
  final Object? value;
  const AnnotationInfo({required this.id, this.value});
}

final class StructSchemaInfo extends SchemaInfo {
  final int dataWords;
  final int pointerWords;
  final bool isGroup;
  final int discriminantCount;
  final int discriminantOffset;
  final List<FieldSchemaInfo> fields;
  final List<String> typeParameters;

  const StructSchemaInfo({
    required super.id,
    required super.displayName,
    required super.shortName,
    required this.dataWords,
    required this.pointerWords,
    required this.fields,
    this.isGroup = false,
    this.discriminantCount = 0,
    this.discriminantOffset = 0,
    this.typeParameters = const [],
    super.annotations,
  });

  FieldSchemaInfo? fieldByName(String name) {
    for (final field in fields) {
      if (field.name == name) return field;
    }
    return null;
  }
}

final class FieldSchemaInfo {
  final String name;
  final int codeOrder;
  final int discriminantValue;
  final FieldBodySchemaInfo body;
  final List<AnnotationInfo> annotations;

  const FieldSchemaInfo({
    required this.name,
    required this.codeOrder,
    required this.body,
    this.discriminantValue = 0xFFFF,
    this.annotations = const [],
  });

  bool get isUnionField => discriminantValue != 0xFFFF;
}

sealed class FieldBodySchemaInfo {
  const FieldBodySchemaInfo();
}

final class SlotFieldSchemaInfo extends FieldBodySchemaInfo {
  final int offset;
  final TypeSchemaInfo type;
  final bool hadExplicitDefault;
  final Object? defaultValue;

  const SlotFieldSchemaInfo({
    required this.offset,
    required this.type,
    this.hadExplicitDefault = false,
    this.defaultValue,
  });
}

final class GroupFieldSchemaInfo extends FieldBodySchemaInfo {
  final int typeId;

  const GroupFieldSchemaInfo({required this.typeId});
}

final class EnumSchemaInfo extends SchemaInfo {
  final List<EnumerantSchemaInfo> enumerants;

  const EnumSchemaInfo({
    required super.id,
    required super.displayName,
    required super.shortName,
    required this.enumerants,
    super.annotations,
  });
}

final class EnumerantSchemaInfo {
  final String name;
  final int codeOrder;
  final List<AnnotationInfo> annotations;

  const EnumerantSchemaInfo({
    required this.name,
    required this.codeOrder,
    this.annotations = const [],
  });
}

final class InterfaceSchemaInfo extends SchemaInfo {
  final List<MethodSchemaInfo> methods;
  final List<int> superclassIds;

  const InterfaceSchemaInfo({
    required super.id,
    required super.displayName,
    required super.shortName,
    this.methods = const [],
    this.superclassIds = const [],
    super.annotations,
  });

  MethodSchemaInfo? methodByName(String name) {
    for (final method in methods) {
      if (method.name == name) return method;
    }
    return null;
  }
}

final class MethodSchemaInfo {
  final String name;
  final int ordinal;
  final int paramStructTypeId;
  final int resultStructTypeId;
  final List<AnnotationInfo> annotations;

  const MethodSchemaInfo({
    required this.name,
    required this.ordinal,
    required this.paramStructTypeId,
    required this.resultStructTypeId,
    this.annotations = const [],
  });
}

sealed class TypeSchemaInfo {
  const TypeSchemaInfo();
}

final class PrimitiveTypeSchemaInfo extends TypeSchemaInfo {
  final String name;

  const PrimitiveTypeSchemaInfo(this.name);
}

final class AnyPointerTypeSchemaInfo extends TypeSchemaInfo {
  const AnyPointerTypeSchemaInfo();
}

final class TypeParameterSchemaInfo extends TypeSchemaInfo {
  final int parameterIndex;

  const TypeParameterSchemaInfo(this.parameterIndex);
}

final class ListTypeSchemaInfo extends TypeSchemaInfo {
  final TypeSchemaInfo elementType;

  const ListTypeSchemaInfo(this.elementType);
}

final class StructRefTypeSchemaInfo extends TypeSchemaInfo {
  final int typeId;
  final List<TypeSchemaInfo> typeArgs;

  const StructRefTypeSchemaInfo(this.typeId, {this.typeArgs = const []});
}

final class EnumRefTypeSchemaInfo extends TypeSchemaInfo {
  final int typeId;

  const EnumRefTypeSchemaInfo(this.typeId);
}

final class InterfaceRefTypeSchemaInfo extends TypeSchemaInfo {
  final int typeId;
  final List<TypeSchemaInfo> typeArgs;

  const InterfaceRefTypeSchemaInfo(this.typeId, {this.typeArgs = const []});
}
