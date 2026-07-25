/// One node in the schema graph (file, struct, enum, interface, const, annotation).
class SchemaNode {
  /// Globally unique id assigned by the capnp compiler (matches the id used
  /// to cross-reference this node from [SchemaNestedNode.id],
  /// [StructRefType.typeId], and similar type/scope references elsewhere in
  /// the schema graph).
  final int id;

  /// Fully qualified name, e.g. `foo.capnp:Bar.Baz`. Use [shortName] for just
  /// the last component (`Baz`).
  final String displayName;

  /// Length of the prefix of [displayName] to strip to get [shortName].
  final int displayNamePrefixLength;

  /// Id of the node this one is nested in (a file, struct, or interface), or
  /// `0` for a top-level file node.
  final int scopeId;

  /// This node's directly nested declarations (structs, enums, etc. declared
  /// inside it), as name→id pairs.
  final List<SchemaNestedNode> nestedNodes;

  /// The node-kind-specific payload — discriminates whether this is a file,
  /// struct, enum, interface, const, or annotation declaration.
  final SchemaNodeBody body;

  /// Names of generic type parameters; empty for non-generic nodes.
  final List<String> parameters;

  /// Annotations applied directly to this node (e.g. `$myAnno(...)` right
  /// after a `struct`/`enum`/`interface` declaration). Empty if none.
  final List<AppliedAnnotation> annotations;

  /// Creates a schema node with the given fields, as parsed from a capnp
  /// `CodeGeneratorRequest`.
  const SchemaNode({
    required this.id,
    required this.displayName,
    required this.displayNamePrefixLength,
    required this.scopeId,
    required this.nestedNodes,
    required this.body,
    this.parameters = const [],
    this.annotations = const [],
  });

  /// Short name: the portion after the prefix (e.g., "Foo" not "schema.Foo").
  String get shortName => displayName.substring(displayNamePrefixLength);
}

/// A single annotation application (e.g. `$myAnno("hello")` in the schema),
/// as opposed to the `annotation myAnno @0x... (...) :Text;` declaration
/// itself (which is just another [SchemaNode] with an [AnnotationBody]).
///
/// [id] is the declaring annotation node's id — look it up in the full node
/// list if you need its name or declared value type. [value] uses the same
/// representation as [ConstBody.value]/[SlotField.defaultValue]:
/// `bool`/`int`/`double` for scalars, `String` for Text, `Uint8List` for
/// Data/List/Struct (the latter two as a standalone single-message byte
/// buffer), or `null` for a Void-valued annotation.
class AppliedAnnotation {
  /// The declaring annotation node's id.
  final int id;

  /// The annotation's value, or `null` for a Void-valued annotation.
  final Object? value;

  /// Creates an applied annotation referencing annotation node [id] with the
  /// given [value].
  const AppliedAnnotation({required this.id, this.value});
}

/// A name→id mapping for a node's nested declarations.
class SchemaNestedNode {
  /// The nested declaration's name, as written in the schema.
  final String name;

  /// The nested declaration's node id — look it up in the full node list to
  /// resolve its [SchemaNode].
  final int id;

  /// Creates a nested-node reference pairing [name] with [id].
  const SchemaNestedNode({required this.name, required this.id});
}

// ---- Node body variants -----------------------------------------------

/// Base class for the node-kind-specific payload of a [SchemaNode.body].
abstract class SchemaNodeBody {
  /// Constructor for subclasses.
  const SchemaNodeBody();
}

/// Body for a node that represents a `.capnp` file itself (the root node of
/// each requested file). Carries no additional data of its own.
class FileBody extends SchemaNodeBody {
  /// Creates a file node body.
  const FileBody();
}

/// Body for a `struct` (or group) declaration.
class StructBody extends SchemaNodeBody {
  /// Number of words in the struct's data section.
  final int dataWordCount;

  /// Number of pointers in the struct's pointer section.
  final int pointerCount;

  /// Whether this struct is actually a group (a named subset of an enclosing
  /// struct's own data/pointer sections, sharing its layout) rather than a
  /// standalone struct with its own storage.
  final bool isGroup;

  /// Number of fields participating in this struct's top-level union
  /// (`0` if the struct has no union).
  final int discriminantCount;

  /// Offset, in UInt16 units from the start of the data section, of the
  /// union discriminant that selects among this struct's union fields.
  final int discriminantOffset; // in UInt16 units from data-section start

  /// This struct's fields, in code order.
  final List<SchemaField> fields;

  /// Creates a struct body with the given layout and fields.
  const StructBody({
    required this.dataWordCount,
    required this.pointerCount,
    required this.isGroup,
    required this.discriminantCount,
    required this.discriminantOffset,
    required this.fields,
  });
}

/// Body for an `enum` declaration.
class EnumBody extends SchemaNodeBody {
  /// The enum's members, in code order.
  final List<SchemaEnumerant> enumerants;

  /// Creates an enum body with the given [enumerants].
  const EnumBody({required this.enumerants});
}

/// A single method declared on an `interface`.
class SchemaMethod {
  /// The method's name, as written in the schema.
  final String name;

  /// Wire-level method ID used in Cap'n Proto Call messages.
  /// Equals the method's position in the interface's ordinal-ordered method list.
  final int ordinal;

  /// Node ID of the auto-generated parameter struct.
  final int paramStructTypeId;

  /// Node ID of the auto-generated result struct.
  final int resultStructTypeId;

  /// Annotations applied directly to this method. Empty if none.
  final List<AppliedAnnotation> annotations;

  /// Creates a method declaration with the given [name], [ordinal], and
  /// auto-generated param/result struct type ids.
  const SchemaMethod({
    required this.name,
    required this.ordinal,
    required this.paramStructTypeId,
    required this.resultStructTypeId,
    this.annotations = const [],
  });
}

/// Body for an `interface` declaration.
class InterfaceBody extends SchemaNodeBody {
  /// The interface's methods, in ordinal order.
  final List<SchemaMethod> methods;

  /// Node ids of the interfaces this one `extends`.
  final List<int> superclassIds;

  /// Creates an interface body with the given [methods] and
  /// [superclassIds].
  const InterfaceBody({this.methods = const [], this.superclassIds = const []});
}

/// Body for a `const` declaration.
class ConstBody extends SchemaNodeBody {
  /// The constant's declared type.
  final SchemaType type;

  /// Same representation as [SlotField.defaultValue]: `bool`/`int`/`double`
  /// for scalars, `String` for Text, `Uint8List` for Data, a standalone
  /// single-message byte buffer (`Uint8List`) for List/Struct, `int` for an
  /// enum's raw ordinal. Null if the value's kind isn't representable this
  /// way (e.g. Void).
  final Object? value;

  /// Creates a const body with the given declared [type] and [value].
  const ConstBody({required this.type, required this.value});
}

/// Body for an `annotation` declaration. Carries no additional data of its
/// own — the declared value type lives on the enclosing [SchemaNode] via its
/// own type machinery, resolved separately when the annotation is applied.
class AnnotationBody extends SchemaNodeBody {
  /// Creates an annotation node body.
  const AnnotationBody();
}

/// A single member of an [EnumBody].
class SchemaEnumerant {
  /// The enumerant's name, as written in the schema.
  final String name;

  /// Textual declaration order within the enum. See [ordinal] for the value
  /// that actually matters for wire compatibility.
  final int codeOrder;

  /// The enumerant's wire value (`@N` in schema source) — the number that
  /// actually determines its encoding on the wire.
  ///
  /// Distinct from [codeOrder] (textual declaration order in the schema
  /// file): exactly like struct fields (see [SchemaField.ordinal]), Cap'n
  /// Proto lets an enum's `@N` annotations be declared out of order (e.g.
  /// `enum Color { red @0; blue @2; green @1; }` is legal and gives `blue`
  /// wire value 2 despite being declared before `green`). Schema-evolution
  /// comparisons, and anything deriving a wire value from list position
  /// (the generated Dart `enum`'s member order, which doubles as its
  /// `.index`), must use [ordinal], not [codeOrder].
  final int ordinal;

  /// Annotations applied directly to this enumerant. Empty if none.
  final List<AppliedAnnotation> annotations;

  /// Creates an enum member with the given [name], [codeOrder], and
  /// [ordinal].
  const SchemaEnumerant({
    required this.name,
    required this.codeOrder,
    required this.ordinal,
    this.annotations = const [],
  });
}

// ---- Field ---------------------------------------------------------------

/// A single field of a [StructBody].
class SchemaField {
  /// The field's name, as written in the schema.
  final String name;

  /// Textual declaration order within the struct. See [ordinal] for the
  /// value that actually matters for wire compatibility.
  final int codeOrder;

  /// The field's wire ordinal (`@N` in schema source) — the number that
  /// actually determines slot allocation and thus wire compatibility.
  ///
  /// Distinct from [codeOrder] (textual declaration order in the schema
  /// file), which two schema versions can legally differ on for the exact
  /// same wire-compatible field set (e.g. reordering declarations without
  /// touching any `@N`). Schema-evolution comparisons must match fields by
  /// [ordinal], not [codeOrder] — matching by the latter would misreport a
  /// pure declaration-order shuffle as type/offset changes.
  final int ordinal;

  /// The union discriminant value that selects this field, or `0xFFFF` if
  /// the field isn't part of a union. See [isUnionField].
  final int discriminantValue; // 0xFFFF if not a union field

  /// Whether this is a plain slot field or a group field.
  final SchemaFieldBody body;

  /// Annotations applied directly to this field. Empty if none.
  final List<AppliedAnnotation> annotations;

  /// Creates a field with the given [name], ordering, [discriminantValue],
  /// and [body].
  const SchemaField({
    required this.name,
    required this.codeOrder,
    required this.ordinal,
    required this.discriminantValue,
    required this.body,
    this.annotations = const [],
  });

  /// Whether this field is a member of the struct's top-level union.
  bool get isUnionField => discriminantValue != 0xFFFF;
}

/// Base class for the two kinds of [SchemaField.body].
abstract class SchemaFieldBody {
  /// Constructor for subclasses.
  const SchemaFieldBody();
}

/// A data-section or pointer-section field with an explicit slot.
class SlotField extends SchemaFieldBody {
  /// Raw offset: for data types in units of (type size); for pointers in pointer slots.
  final int offset;

  /// The field's declared type.
  final SchemaType type;

  /// Whether the schema explicitly wrote a default value for this field
  /// (as opposed to it being the type's implicit zero/false/absent default).
  final bool hadExplicitDefault;

  /// The default value for this field, or null if zero/false/absent.
  /// Stored as [int] for integer/enum types, [bool] for Bool, [double] for floats.
  final Object? defaultValue;

  /// Creates a slot field with the given [offset], [type], and default-value
  /// info.
  const SlotField({
    required this.offset,
    required this.type,
    required this.hadExplicitDefault,
    this.defaultValue,
  });
}

/// A group field (reference to another struct node that acts as a view).
class GroupField extends SchemaFieldBody {
  /// Node id of the group's own struct declaration.
  final int typeId;

  /// Creates a group field referencing struct node [typeId].
  const GroupField({required this.typeId});
}

// ---- Type ----------------------------------------------------------------

/// Base class for every field/const/method-parameter type in the schema
/// graph — one subclass per Cap'n Proto primitive kind, plus
/// [ListType]/[StructRefType]/[EnumRefType]/[InterfaceRefType]/
/// [TypeParameterRefType] for composite and reference types.
abstract class SchemaType {
  /// Constructor for subclasses.
  const SchemaType();
}

/// The `Void` type.
class VoidType extends SchemaType {
  /// Creates a `Void` type.
  const VoidType();
}

/// The `Bool` type.
class BoolType extends SchemaType {
  /// Creates a `Bool` type.
  const BoolType();
}

/// The `Int8` type.
class Int8Type extends SchemaType {
  /// Creates an `Int8` type.
  const Int8Type();
}

/// The `Int16` type.
class Int16Type extends SchemaType {
  /// Creates an `Int16` type.
  const Int16Type();
}

/// The `Int32` type.
class Int32Type extends SchemaType {
  /// Creates an `Int32` type.
  const Int32Type();
}

/// The `Int64` type.
class Int64Type extends SchemaType {
  /// Creates an `Int64` type.
  const Int64Type();
}

/// The `UInt8` type.
class UInt8Type extends SchemaType {
  /// Creates a `UInt8` type.
  const UInt8Type();
}

/// The `UInt16` type.
class UInt16Type extends SchemaType {
  /// Creates a `UInt16` type.
  const UInt16Type();
}

/// The `UInt32` type.
class UInt32Type extends SchemaType {
  /// Creates a `UInt32` type.
  const UInt32Type();
}

/// The `UInt64` type.
class UInt64Type extends SchemaType {
  /// Creates a `UInt64` type.
  const UInt64Type();
}

/// The `Float32` type.
class Float32Type extends SchemaType {
  /// Creates a `Float32` type.
  const Float32Type();
}

/// The `Float64` type.
class Float64Type extends SchemaType {
  /// Creates a `Float64` type.
  const Float64Type();
}

/// The `Text` type.
class TextType extends SchemaType {
  /// Creates a `Text` type.
  const TextType();
}

/// The `Data` type.
class DataType extends SchemaType {
  /// Creates a `Data` type.
  const DataType();
}

/// The `AnyPointer` type (including its generic-parameter special cases,
/// which are instead represented by [TypeParameterRefType]).
class AnyPointerType extends SchemaType {
  /// Creates an `AnyPointer` type.
  const AnyPointerType();
}

/// Represents a generic type parameter (e.g., `Key` in `struct KeyValue(Key, Value)`).
/// Used in template struct nodes; replaced by concrete types in specializations.
class TypeParameterRefType extends SchemaType {
  /// Index of the parameter within the owning scope's `parameters` list —
  /// see [scopeId] for which node's list that is.
  final int parameterIndex;

  /// Node id of the generic scope that owns this parameter.
  ///
  /// Usually the struct itself (e.g. `struct Foo(T)`, or a method's own
  /// implicit `[T]` parameters — the compiler gives that method's
  /// auto-generated params/results struct its own matching `parameters`
  /// list, so [parameterIndex] indexes into that same node's `parameters`).
  ///
  /// But when `T` is instead the *enclosing interface's* own type parameter
  /// (`interface Foo(T) { bar @0 () -> (value :T); }`), the auto-generated
  /// `bar$Results` struct has an *empty* `parameters` list of its own —
  /// [scopeId] is `Foo`'s node id instead, and [parameterIndex] indexes into
  /// `Foo`'s `parameters`, not `bar$Results`'s. Defaults to 0 (meaning
  /// "unknown/not set", not a valid node id) for callers that don't need
  /// scope-aware resolution — see `_writeTypedClientMethod` in the
  /// generator for where this actually matters.
  final int scopeId;

  /// Creates a reference to generic parameter [parameterIndex], optionally
  /// scoped to node [scopeId].
  const TypeParameterRefType(this.parameterIndex, {this.scopeId = 0});
}

/// A `List(T)` type.
class ListType extends SchemaType {
  /// The list's element type.
  final SchemaType elementType;

  /// Creates a list type with the given [elementType].
  const ListType(this.elementType);
}

/// A reference to a `struct` type, by node id.
class StructRefType extends SchemaType {
  /// The referenced struct node's id.
  final int typeId;

  /// Non-empty when this reference is a concrete generic instantiation (e.g., KeyValue(Text, Text)).
  final List<SchemaType> typeArgs;

  /// Creates a reference to struct node [typeId], optionally instantiated
  /// with [typeArgs].
  const StructRefType(this.typeId, {this.typeArgs = const []});
}

/// A reference to an `enum` type, by node id.
class EnumRefType extends SchemaType {
  /// The referenced enum node's id.
  final int typeId;

  /// Creates a reference to enum node [typeId].
  const EnumRefType(this.typeId);
}

/// A reference to an `interface` type, by node id.
class InterfaceRefType extends SchemaType {
  /// The referenced interface node's id.
  final int typeId;

  /// Non-empty when this reference is a concrete generic instantiation.
  final List<SchemaType> typeArgs;

  /// Creates a reference to interface node [typeId], optionally instantiated
  /// with [typeArgs].
  const InterfaceRefType(this.typeId, {this.typeArgs = const []});
}

/// The complete request received from the capnp compiler.
class CodeGeneratorRequest {
  /// Every node in the schema graph, across all requested files and their
  /// transitive imports.
  final List<SchemaNode> nodes;

  /// The files the compiler was asked to generate code for (a subset of the
  /// files whose nodes appear in [nodes] — imported-only files are included
  /// in [nodes] but not here).
  final List<RequestedFile> requestedFiles;

  /// Creates a code generator request with the given [nodes] and
  /// [requestedFiles].
  const CodeGeneratorRequest({
    required this.nodes,
    required this.requestedFiles,
  });
}

/// One file the capnp compiler was asked to generate code for.
class RequestedFile {
  /// The file's own node id — look it up in [CodeGeneratorRequest.nodes] to
  /// resolve its [SchemaNode] (a [FileBody]).
  final int id;

  /// The file's path, as passed to the compiler.
  final String filename;

  /// Creates a requested-file entry for node [id] at [filename].
  const RequestedFile({required this.id, required this.filename});
}
