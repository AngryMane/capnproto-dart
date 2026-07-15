/// One node in the schema graph (file, struct, enum, interface, const, annotation).
class SchemaNode {
  final int id;
  final String displayName;
  final int displayNamePrefixLength;
  final int scopeId;
  final List<SchemaNestedNode> nestedNodes;
  final SchemaNodeBody body;

  const SchemaNode({
    required this.id,
    required this.displayName,
    required this.displayNamePrefixLength,
    required this.scopeId,
    required this.nestedNodes,
    required this.body,
  });

  /// Short name: the portion after the prefix (e.g., "Foo" not "schema.Foo").
  String get shortName => displayName.substring(displayNamePrefixLength);
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

  const SchemaMethod({
    required this.name,
    required this.ordinal,
    required this.paramStructTypeId,
    required this.resultStructTypeId,
  });
}

class InterfaceBody extends SchemaNodeBody {
  final List<SchemaMethod> methods;
  final List<int> superclassIds;
  const InterfaceBody({this.methods = const [], this.superclassIds = const []});
}

class ConstBody extends SchemaNodeBody {
  const ConstBody();
}

class AnnotationBody extends SchemaNodeBody {
  const AnnotationBody();
}

class SchemaEnumerant {
  final String name;
  final int codeOrder;
  const SchemaEnumerant({required this.name, required this.codeOrder});
}

// ---- Field ---------------------------------------------------------------

class SchemaField {
  final String name;
  final int codeOrder;
  final int discriminantValue; // 0xFFFF if not a union field
  final SchemaFieldBody body;

  const SchemaField({
    required this.name,
    required this.codeOrder,
    required this.discriminantValue,
    required this.body,
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

  const SlotField({
    required this.offset,
    required this.type,
    required this.hadExplicitDefault,
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

class ListType extends SchemaType {
  final SchemaType elementType;
  const ListType(this.elementType);
}

class StructRefType extends SchemaType {
  final int typeId;
  const StructRefType(this.typeId);
}

class EnumRefType extends SchemaType {
  final int typeId;
  const EnumRefType(this.typeId);
}

class InterfaceRefType extends SchemaType {
  final int typeId;
  const InterfaceRefType(this.typeId);
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
