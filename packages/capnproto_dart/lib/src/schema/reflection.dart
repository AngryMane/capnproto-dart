/// Lightweight schema reflection metadata emitted by `capnpc-dart`.
///
/// These classes intentionally model the information most useful at runtime:
/// node ids, names, struct layout, fields, enum values, and interface methods.
/// They are not a full in-memory representation of `schema.capnp`.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
sealed class SchemaInfo {
  /// Holds the public [id] value.
  final int id;

  /// Holds the public [displayName] value.
  final String displayName;

  /// Holds the public [shortName] value.
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
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class AnnotationInfo {
  /// Holds the public [id] value.
  final int id;

  /// Holds the public [value] value.
  final Object? value;

  /// Creates a [AnnotationInfo] instance.
  const AnnotationInfo({required this.id, this.value});
}

/// Describes the runtime layout and fields of a struct schema node.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class StructSchemaInfo extends SchemaInfo {
  /// Holds the public [dataWords] value.
  final int dataWords;

  /// Holds the public [pointerWords] value.
  final int pointerWords;

  /// Holds the public [isGroup] value.
  final bool isGroup;

  /// Holds the public [discriminantCount] value.
  final int discriminantCount;

  /// Holds the public [discriminantOffset] value.
  final int discriminantOffset;

  /// Holds the public [fields] value.
  final List<FieldSchemaInfo> fields;

  /// Holds the public [typeParameters] value.
  final List<String> typeParameters;

  /// Creates a [StructSchemaInfo] instance.
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

  /// Performs the [fieldByName] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final field = schema.fieldByName('name');
  /// ```
  FieldSchemaInfo? fieldByName(String name) {
    for (final field in fields) {
      if (field.name == name) return field;
    }
    return null;
  }
}

/// Describes a named struct field and its union metadata.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class FieldSchemaInfo {
  /// Holds the public [name] value.
  final String name;

  /// Holds the public [codeOrder] value.
  final int codeOrder;

  /// Holds the public [discriminantValue] value.
  final int discriminantValue;

  /// Holds the public [body] value.
  final FieldBodySchemaInfo body;

  /// Holds the public [annotations] value.
  final List<AnnotationInfo> annotations;

  /// Creates a [FieldSchemaInfo] instance.
  const FieldSchemaInfo({
    required this.name,
    required this.codeOrder,
    required this.body,
    this.discriminantValue = 0xFFFF,
    this.annotations = const [],
  });

  /// Returns the current [isUnionField] value.
  bool get isUnionField => discriminantValue != 0xFFFF;
}

/// Represents the body of a slot or group field.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
sealed class FieldBodySchemaInfo {
  const FieldBodySchemaInfo();
}

/// Describes a data or pointer slot field.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class SlotFieldSchemaInfo extends FieldBodySchemaInfo {
  /// Holds the public [offset] value.
  final int offset;

  /// Holds the public [type] value.
  final TypeSchemaInfo type;

  /// Holds the public [hadExplicitDefault] value.
  final bool hadExplicitDefault;

  /// Holds the public [defaultValue] value.
  final Object? defaultValue;

  /// Creates a [SlotFieldSchemaInfo] instance.
  const SlotFieldSchemaInfo({
    required this.offset,
    required this.type,
    this.hadExplicitDefault = false,
    this.defaultValue,
  });
}

/// Describes a group field by its struct type ID.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class GroupFieldSchemaInfo extends FieldBodySchemaInfo {
  /// Holds the public [typeId] value.
  final int typeId;

  /// Creates a [GroupFieldSchemaInfo] instance.
  const GroupFieldSchemaInfo({required this.typeId});
}

/// Describes an enum schema node and its enumerants.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class EnumSchemaInfo extends SchemaInfo {
  /// Holds the public [enumerants] value.
  final List<EnumerantSchemaInfo> enumerants;

  /// Creates a [EnumSchemaInfo] instance.
  const EnumSchemaInfo({
    required super.id,
    required super.displayName,
    required super.shortName,
    required this.enumerants,
    super.annotations,
  });
}

/// Describes one enum value and its wire ordinal.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class EnumerantSchemaInfo {
  /// Holds the public [name] value.
  final String name;

  /// Holds the public [codeOrder] value.
  final int codeOrder;

  /// The enumerant's wire value (`@N` in schema source).
  ///
  /// Distinct from [codeOrder] (textual declaration order): Cap'n Proto
  /// lets an enum's `@N`s be declared out of order (e.g. `enum Color { red
  /// @0; blue @2; green @1; }`), so [ordinal] — not [codeOrder] and not
  /// list position — is the only reliable source of an enumerant's actual
  /// wire value. Anything reconstructing a wire value from this list (text
  /// format, dynamic access) must key off [ordinal].
  final int ordinal;

  /// Holds the public [annotations] value.
  final List<AnnotationInfo> annotations;

  /// Creates a [EnumerantSchemaInfo] instance.
  const EnumerantSchemaInfo({
    required this.name,
    required this.codeOrder,
    required this.ordinal,
    this.annotations = const [],
  });
}

/// Describes an interface schema node, methods, and superclasses.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class InterfaceSchemaInfo extends SchemaInfo {
  /// Holds the public [methods] value.
  final List<MethodSchemaInfo> methods;

  /// Holds the public [superclassIds] value.
  final List<int> superclassIds;

  /// Creates a [InterfaceSchemaInfo] instance.
  const InterfaceSchemaInfo({
    required super.id,
    required super.displayName,
    required super.shortName,
    this.methods = const [],
    this.superclassIds = const [],
    super.annotations,
  });

  /// Performs the [methodByName] operation.
  ///
  /// **Example**
  /// ```dart
  /// // Given the required message, schema, or raw-layout values:
  /// final method = schema.methodByName('call');
  /// ```
  MethodSchemaInfo? methodByName(String name) {
    for (final method in methods) {
      if (method.name == name) return method;
    }
    return null;
  }
}

/// Describes an interface method and its parameter and result types.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class MethodSchemaInfo {
  /// Holds the public [name] value.
  final String name;

  /// Holds the public [ordinal] value.
  final int ordinal;

  /// Holds the public [paramStructTypeId] value.
  final int paramStructTypeId;

  /// Holds the public [resultStructTypeId] value.
  final int resultStructTypeId;

  /// Holds the public [annotations] value.
  final List<AnnotationInfo> annotations;

  /// Creates a [MethodSchemaInfo] instance.
  const MethodSchemaInfo({
    required this.name,
    required this.ordinal,
    required this.paramStructTypeId,
    required this.resultStructTypeId,
    this.annotations = const [],
  });
}

/// Represents a field or type-parameter type in runtime schema metadata.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
sealed class TypeSchemaInfo {
  const TypeSchemaInfo();
}

/// Describes a primitive schema type by name.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class PrimitiveTypeSchemaInfo extends TypeSchemaInfo {
  /// Holds the public [name] value.
  final String name;

  /// Creates a [PrimitiveTypeSchemaInfo] instance.
  const PrimitiveTypeSchemaInfo(this.name);
}

/// Identifies an AnyPointer schema type.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class AnyPointerTypeSchemaInfo extends TypeSchemaInfo {
  /// Creates a [AnyPointerTypeSchemaInfo] instance.
  const AnyPointerTypeSchemaInfo();
}

/// Identifies a generic schema type parameter by index.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class TypeParameterSchemaInfo extends TypeSchemaInfo {
  /// Holds the public [parameterIndex] value.
  final int parameterIndex;

  /// Creates a [TypeParameterSchemaInfo] instance.
  const TypeParameterSchemaInfo(this.parameterIndex);
}

/// Describes a list schema type and its element type.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class ListTypeSchemaInfo extends TypeSchemaInfo {
  /// Holds the public [elementType] value.
  final TypeSchemaInfo elementType;

  /// Creates a [ListTypeSchemaInfo] instance.
  const ListTypeSchemaInfo(this.elementType);
}

/// References a struct schema type and its type arguments.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class StructRefTypeSchemaInfo extends TypeSchemaInfo {
  /// Holds the public [typeId] value.
  final int typeId;

  /// Holds the public [typeArgs] value.
  final List<TypeSchemaInfo> typeArgs;

  /// Creates a [StructRefTypeSchemaInfo] instance.
  const StructRefTypeSchemaInfo(this.typeId, {this.typeArgs = const []});
}

/// References an enum schema type by node ID.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class EnumRefTypeSchemaInfo extends TypeSchemaInfo {
  /// Holds the public [typeId] value.
  final int typeId;

  /// Creates a [EnumRefTypeSchemaInfo] instance.
  const EnumRefTypeSchemaInfo(this.typeId);
}

/// References an interface schema type and its type arguments.
///
/// **Intended users**
/// * Generated bindings and developers building reflection-driven or RPC integrations.
///
/// **Primary use cases**
/// * Supports values whose schema or concrete Dart type is selected at runtime.
final class InterfaceRefTypeSchemaInfo extends TypeSchemaInfo {
  /// Holds the public [typeId] value.
  final int typeId;

  /// Holds the public [typeArgs] value.
  final List<TypeSchemaInfo> typeArgs;

  /// Creates a [InterfaceRefTypeSchemaInfo] instance.
  const InterfaceRefTypeSchemaInfo(this.typeId, {this.typeArgs = const []});
}
