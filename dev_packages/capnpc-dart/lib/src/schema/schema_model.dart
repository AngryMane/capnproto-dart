/// One node in the schema graph (file, struct, enum, interface, const, annotation).
class SchemaNode {
  final int id;
  final String displayName;
  final int displayNamePrefixLength;
  final int scopeId;
  final List<SchemaNestedNode> nestedNodes;
  final SchemaNodeBody body;
  /// Names of generic type parameters; empty for non-generic nodes.
  final List<String> parameters;
  /// Annotations applied directly to this node (e.g. `$myAnno(...)` right
  /// after a `struct`/`enum`/`interface` declaration). Empty if none.
  final List<AppliedAnnotation> annotations;

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
  final int id;
  final Object? value;
  const AppliedAnnotation({required this.id, this.value});
}

/// A name→id mapping for a node's nested declarations.
class SchemaNestedNode {
  final String name;
  final int id;
  const SchemaNestedNode({required this.name, required this.id});
}

// ---- Node body variants -----------------------------------------------

abstract class SchemaNodeBody {
  const SchemaNodeBody();
}

class FileBody extends SchemaNodeBody {
  const FileBody();
}

class StructBody extends SchemaNodeBody {
  final int dataWordCount;
  final int pointerCount;
  final bool isGroup;
  final int discriminantCount;
  final int discriminantOffset; // in UInt16 units from data-section start
  final List<SchemaField> fields;

  const StructBody({
    required this.dataWordCount,
    required this.pointerCount,
    required this.isGroup,
    required this.discriminantCount,
    required this.discriminantOffset,
    required this.fields,
  });
}

class EnumBody extends SchemaNodeBody {
  final List<SchemaEnumerant> enumerants;
  const EnumBody({required this.enumerants});
}

class SchemaMethod {
  final String name;

  /// Wire-level method ID used in Cap'n Proto Call messages.
  /// Equals the method's position in the interface's ordinal-ordered method list.
  final int ordinal;

  /// Node ID of the auto-generated parameter struct.
  final int paramStructTypeId;

  /// Node ID of the auto-generated result struct.
  final int resultStructTypeId;

  final List<AppliedAnnotation> annotations;

  const SchemaMethod({
    required this.name,
    required this.ordinal,
    required this.paramStructTypeId,
    required this.resultStructTypeId,
    this.annotations = const [],
  });
}

class InterfaceBody extends SchemaNodeBody {
  final List<SchemaMethod> methods;
  final List<int> superclassIds;
  const InterfaceBody({this.methods = const [], this.superclassIds = const []});
}

class ConstBody extends SchemaNodeBody {
  final SchemaType type;

  /// Same representation as [SlotField.defaultValue]: `bool`/`int`/`double`
  /// for scalars, `String` for Text, `Uint8List` for Data, a standalone
  /// single-message byte buffer (`Uint8List`) for List/Struct, `int` for an
  /// enum's raw ordinal. Null if the value's kind isn't representable this
  /// way (e.g. Void).
  final Object? value;

  const ConstBody({required this.type, required this.value});
}

class AnnotationBody extends SchemaNodeBody {
  const AnnotationBody();
}

class SchemaEnumerant {
  final String name;
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
  final List<AppliedAnnotation> annotations;
  const SchemaEnumerant({
    required this.name,
    required this.codeOrder,
    required this.ordinal,
    this.annotations = const [],
  });
}

// ---- Field ---------------------------------------------------------------

class SchemaField {
  final String name;
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
  final int discriminantValue; // 0xFFFF if not a union field
  final SchemaFieldBody body;
  final List<AppliedAnnotation> annotations;

  const SchemaField({
    required this.name,
    required this.codeOrder,
    required this.ordinal,
    required this.discriminantValue,
    required this.body,
    this.annotations = const [],
  });

  bool get isUnionField => discriminantValue != 0xFFFF;
}

abstract class SchemaFieldBody {
  const SchemaFieldBody();
}

/// A data-section or pointer-section field with an explicit slot.
class SlotField extends SchemaFieldBody {
  /// Raw offset: for data types in units of (type size); for pointers in pointer slots.
  final int offset;
  final SchemaType type;
  final bool hadExplicitDefault;
  /// The default value for this field, or null if zero/false/absent.
  /// Stored as [int] for integer/enum types, [bool] for Bool, [double] for floats.
  final Object? defaultValue;

  const SlotField({
    required this.offset,
    required this.type,
    required this.hadExplicitDefault,
    this.defaultValue,
  });
}

/// A group field (reference to another struct node that acts as a view).
class GroupField extends SchemaFieldBody {
  final int typeId;
  const GroupField({required this.typeId});
}

// ---- Type ----------------------------------------------------------------

abstract class SchemaType {
  const SchemaType();
}

class VoidType extends SchemaType { const VoidType(); }
class BoolType extends SchemaType { const BoolType(); }
class Int8Type extends SchemaType { const Int8Type(); }
class Int16Type extends SchemaType { const Int16Type(); }
class Int32Type extends SchemaType { const Int32Type(); }
class Int64Type extends SchemaType { const Int64Type(); }
class UInt8Type extends SchemaType { const UInt8Type(); }
class UInt16Type extends SchemaType { const UInt16Type(); }
class UInt32Type extends SchemaType { const UInt32Type(); }
class UInt64Type extends SchemaType { const UInt64Type(); }
class Float32Type extends SchemaType { const Float32Type(); }
class Float64Type extends SchemaType { const Float64Type(); }
class TextType extends SchemaType { const TextType(); }
class DataType extends SchemaType { const DataType(); }
class AnyPointerType extends SchemaType { const AnyPointerType(); }

/// Represents a generic type parameter (e.g., `Key` in `struct KeyValue(Key, Value)`).
/// Used in template struct nodes; replaced by concrete types in specializations.
class TypeParameterRefType extends SchemaType {
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

  const TypeParameterRefType(this.parameterIndex, {this.scopeId = 0});
}

class ListType extends SchemaType {
  final SchemaType elementType;
  const ListType(this.elementType);
}

class StructRefType extends SchemaType {
  final int typeId;
  /// Non-empty when this reference is a concrete generic instantiation (e.g., KeyValue(Text, Text)).
  final List<SchemaType> typeArgs;
  const StructRefType(this.typeId, {this.typeArgs = const []});
}

class EnumRefType extends SchemaType {
  final int typeId;
  const EnumRefType(this.typeId);
}

class InterfaceRefType extends SchemaType {
  final int typeId;
  /// Non-empty when this reference is a concrete generic instantiation.
  final List<SchemaType> typeArgs;
  const InterfaceRefType(this.typeId, {this.typeArgs = const []});
}

/// The complete request received from the capnp compiler.
class CodeGeneratorRequest {
  final List<SchemaNode> nodes;
  final List<RequestedFile> requestedFiles;

  const CodeGeneratorRequest({
    required this.nodes,
    required this.requestedFiles,
  });
}

class RequestedFile {
  final int id;
  final String filename;
  const RequestedFile({required this.id, required this.filename});
}
