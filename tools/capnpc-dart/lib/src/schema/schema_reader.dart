import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import 'schema_model.dart';

// ---------------------------------------------------------------------------
// Binary layout constants derived from the published schema.capnp specification.
// All byte offsets are from the start of the struct's data section.
// Pointer indices are from the start of the pointer section.
//
// Layout algorithm: fields are sorted by size class (largest first), then by
// field ordinal.  This produces a deterministic, stable layout that has not
// changed since capnp v0.6.
//
// To verify these values, run:
//   capnp compile -o capnp /usr/include/capnp/schema.capnp
// and inspect the resulting binary.
// ---------------------------------------------------------------------------

// ---- Node @0xe682ab4cf923a417 (dataWords=5, ptrWords=6) ----
//
// Layout: ordinal-first within each size class.
// Verified against the binary produced by `capnp compile -o <plugin> greeter.capnp`.
//
// Data section:
//   bytes  0- 7 : id (UInt64, @0)
//   bytes  8-11 : displayNamePrefixLength (UInt32, @2)
//   bytes 12-13 : union discriminant (UInt16)
//                 0=file 1=struct 2=enum 3=interface 4=const 5=annotation
//   bytes 14-15 : struct.dataWordCount (UInt16, @7)
//   bytes 16-23 : scopeId (UInt64, @3)
//   bytes 24-25 : struct.pointerCount (UInt16, @8)
//   bytes 26-27 : struct.preferredListEncoding (UInt16, @9)
//   byte  28 b0 : struct.isGroup (Bool, @10)  — bit 224
//   bytes 30-31 : struct.discriminantCount (UInt16, @11)
//   bytes 32-35 : struct.discriminantOffset (UInt32, @12)
//   byte  36 b0 : isGeneric (Bool, @33)       — bit 288
// Pointer section:
//   ptr 0 : displayName (Text, @1)
//   ptr 1 : nestedNodes (List(NestedNode), @4)
//   ptr 2 : annotations (List(Annotation), @5)
//   ptr 3 : struct.fields @13 / enum.enumerants @14 / interface.methods @15
//            / const.type @16 / annotation.type @18  (union — shared slot)
//   ptr 4 : interface.superclasses @31 / const.value @17  (union — shared slot)
//   ptr 5 : parameters (List(Parameter), @32)

const _nodeUnionDiscriminant = 12; // byte offset
const _nodeStructDwc = 14;
const _nodeStructPtrCount = 24;
const _nodeStructIsGroupBit = 224; // bit index (byte 28, bit 0)
const _nodeStructDiscriminantCount = 30;
const _nodeStructDiscriminantOffset = 32;
const _nodeStructFieldsPtr = 3;
const _nodeEnumEnumerantsPtr = 3;

class _NodeReader extends StructReader {
  _NodeReader(super.raw);

  int get id => getUint64Field(0);
  String? get displayName => getTextField(0);
  int get displayNamePrefixLength => getUint32Field(8);
  int get scopeId => getUint64Field(16);
  int get _unionDisc => getUint16Field(_nodeUnionDiscriminant);

  ListReader<_NestedNodeReader>? get nestedNodes =>
      getStructListFieldWith(1, (r) => _NestedNodeReader(r));

  // union = struct
  int get structDataWordCount => getUint16Field(_nodeStructDwc);
  int get structPointerCount => getUint16Field(_nodeStructPtrCount);
  bool get structIsGroup => getBoolField(_nodeStructIsGroupBit);
  int get structDiscriminantCount => getUint16Field(_nodeStructDiscriminantCount);
  int get structDiscriminantOffset => getUint32Field(_nodeStructDiscriminantOffset);

  ListReader<_FieldReader>? get structFields =>
      getStructListFieldWith(_nodeStructFieldsPtr, (r) => _FieldReader(r));

  // union = enum
  ListReader<_EnumerantReader>? get enumEnumerants =>
      getStructListFieldWith(_nodeEnumEnumerantsPtr, (r) => _EnumerantReader(r));

  // union = interface
  // methods share ptr slot 3 with struct.fields and enum.enumerants.
  ListReader<_MethodReader>? get interfaceMethods =>
      getStructListFieldWith(3, (r) => _MethodReader(r));

  // interface.superclasses @31 shares ptr slot 4 with const.value @17
  ListReader<_SuperclassReader>? get interfaceSuperclasses =>
      getStructListFieldWith(4, (r) => _SuperclassReader(r));

  // parameters @32 at ptr slot 5 — non-empty for generic nodes
  ListReader<_ParameterReader>? get parameters =>
      getStructListFieldWith(5, (r) => _ParameterReader(r));
}

// ---- Node.NestedNode @0xdebb25476f7ebf4d (dataWords=1, ptrWords=1) ----
//   bytes 0-7 : id (UInt64, @1)
//   ptr 0     : name (Text, @0)
class _NestedNodeReader extends StructReader {
  _NestedNodeReader(super.raw);
  String? get name => getTextField(0);
  int get id => getUint64Field(0);
}

// ---- Field @0x9aad50a41f4af45f (dataWords=3, ptrWords=4) ----
//
// Ordinal-first layout verified against greeter.capnp binary.
//
// Data section:
//   bytes  0- 1 : codeOrder (UInt16, @1)
//   bytes  2- 3 : discriminantValue (UInt16, @3, default=0xffff)
//   bytes  4- 7 : slot.offset (UInt32, @4)
//   bytes  8- 9 : slot/group discriminant (0=slot, 1=group)
//   bytes 10-11 : ordinal discriminant (0=implicit, 1=explicit)
//   bytes 12-13 : ordinal.explicit (UInt16, @9)
//   byte  16 b0 : slot.hadExplicitDefault (Bool, @10) — bit 128
//   bytes 16-23 : group.typeId (UInt64, @7)
// Pointer section:
//   ptr 0 : name (Text, @0)
//   ptr 1 : annotations (List(Annotation), @2)
//   ptr 2 : slot.type (Type, @5)
//   ptr 3 : slot.defaultValue (Value, @6)

class _FieldReader extends StructReader {
  _FieldReader(super.raw);

  String? get name => getTextField(0);
  int get codeOrder => getUint16Field(0);
  int get discriminantValue => getUint16Field(2, defaultValue: 0xffff);
  int get _slotGroupDisc => getUint16Field(8);

  // Field.ordinal :union { implicit @7 :Void; explicit @8 :UInt16; } —
  // verified against real `capnp compile -o-` output (capnp 1.0.1): disc at
  // byte 10-11 (0=implicit, 1=explicit), value at byte 12-13. Every field
  // declared with normal `.capnp` syntax (`name @N :Type`) gets an explicit
  // ordinal from the compiler; the implicit case only exists for the wire
  // format's own theoretical completeness, so codeOrder is a reasonable
  // fallback for it (matches this reader's behavior before ordinal existed).
  int get _ordinalDisc => getUint16Field(10);
  int get _ordinalExplicit => getUint16Field(12);
  int get ordinal => _ordinalDisc == 1 ? _ordinalExplicit : codeOrder;

  // slot fields
  int get slotOffset => getUint32Field(4);
  bool get slotHadExplicitDefault => getBoolField(128); // byte 16, bit 0

  _TypeReader? get slotType => getStructFieldWith(2, (r) => _TypeReader(r));
  _ValueReader? get slotDefaultValue => getStructFieldWith(3, (r) => _ValueReader(r));

  // group field
  int get groupTypeId => getUint64Field(16);

  bool get isSlot => _slotGroupDisc == 0;
  bool get isGroup => _slotGroupDisc == 1;
}

// ---- Type @0xd07378ede1f9cc87 (dataWords=3, ptrWords=1) ----
//
// Ordinal-first layout: the union discriminant (@0=void, lowest ordinal)
// occupies the first UInt16 slot. The UInt64 typeId fields (enums @15, structs
// @16, interfaces @17) follow at bytes 8-15.
//
// Data section:
//   bytes  0- 1 : main union discriminant (UInt16)
//                 0=Void 1=Bool 2=Int8 3=Int16 4=Int32 5=Int64
//                 6=UInt8 7=UInt16 8=UInt32 9=UInt64 10=Float32 11=Float64
//                 12=Text 13=Data 14=List 15=Enum 16=Struct 17=Interface
//                 18=AnyPointer
//   bytes  8- 9 : anyPointer inner union disc (when main=18, u16 index 4)
//                 0=unconstrained, 1=parameter, 2=implicitMethodParameter
//   bytes 10-11 : parameterIndex (main=18, inner=1 or 2, u16 index 5)
//   bytes  8-15 : typeId (enum/struct/interface, u64 index 1)
//   bytes 16-23 : scopeId (anyPointer.parameter, u64 index 2)
// Pointer section:
//   ptr 0 : list.elementType (Type) / struct|enum|interface brand (Brand) / ...

class _TypeReader extends StructReader {
  _TypeReader(super.raw);

  int get _disc => getUint16Field(0);
  int get typeId => getUint64Field(8);

  // anyPointer sub-discriminant at u16 index 4 = bytes 8-9
  int get _anyPtrDisc => getUint16Field(8);
  bool get isTypeParameter => _disc == 18 && _anyPtrDisc == 1;
  int get typeParameterIndex => getUint16Field(10); // u16 index 5 = bytes 10-11
  int get typeParameterScopeId => getUint64Field(16); // u64 index 2 = bytes 16-23

  // ptr 0: listElementType (list variant) OR brand (struct/enum/interface variant)
  _TypeReader? get listElementType => getStructFieldWith(0, (r) => _TypeReader(r));
  _BrandReader? get brand => getStructFieldWith(0, (r) => _BrandReader(r));
}

// ---- Brand @0x903455f06065422b (dataWords=0, ptrWords=1) ----
//   ptr 0 : scopes (List(Scope))
class _BrandReader extends StructReader {
  _BrandReader(super.raw);
  ListReader<_BrandScopeReader>? get scopes =>
      getStructListFieldWith(0, (r) => _BrandScopeReader(r));
}

// ---- Brand.Scope @0xabd73485a9636bc9 (dataWords=2, ptrWords=1) ----
//   bytes 0-7 : scopeId (UInt64, @0)
//   bytes 8-9 : union disc — 0=bind, 1=inherit
//   ptr 0     : bind = List(Binding)
class _BrandScopeReader extends StructReader {
  _BrandScopeReader(super.raw);
  int get scopeId => getUint64Field(0);
  int get _disc => getUint16Field(8);
  bool get isBind => _disc == 0;
  ListReader<_BrandBindingReader>? get bindings =>
      getStructListFieldWith(0, (r) => _BrandBindingReader(r));
}

// ---- Brand.Scope.Binding @0xc863cd16969ee7fc (dataWords=1, ptrWords=1) ----
//   bytes 0-1 : union disc — 0=unbound, 1=type
//   ptr 0     : type (Type, when disc=1)
class _BrandBindingReader extends StructReader {
  _BrandBindingReader(super.raw);
  int get _disc => getUint16Field(0);
  bool get isType => _disc == 1;
  _TypeReader? get type => getStructFieldWith(0, (r) => _TypeReader(r));
}

// ---- Enumerant @0x978a7cebdc549a4d (dataWords=1, ptrWords=2) ----
//   bytes 0-1 : codeOrder (UInt16, @1)
//   ptr 0     : name (Text, @0)
//   ptr 1     : annotations (List(Annotation), @2)
class _EnumerantReader extends StructReader {
  _EnumerantReader(super.raw);
  String? get name => getTextField(0);
  int get codeOrder => getUint16Field(0);
}

// ---- Value @0xce23dcd2310250fa (dataWords=2, ptrWords=1) ----
//
// Data section:
//   bytes 0-1 : discriminant (UInt16)
//               0=void 1=bool 2=int8 3=int16 4=int32 5=int64
//               6=uint8 7=uint16 8=uint32 9=uint64 10=float32 11=float64
//               12=text 13=data 14=list 15=enum 16=struct 17=interface 18=anyPointer
//   byte  2   : bool value (bit 16) / int8 / uint8
//   bytes 2-3 : int16 / uint16 / enum (uint16)
//   bytes 4-7 : int32 / uint32 / float32
//   bytes 8-15: int64 / uint64 / float64
// Pointer section:
//   ptr 0 : text/data/list/struct/anyPointer
class _ValueReader extends StructReader {
  _ValueReader(super.raw);
  int get disc => getUint16Field(0);
  bool get boolValue => getBoolField(16); // byte 2, bit 0
  int get int8Value => getInt8Field(2);
  int get int16Value => getInt16Field(2);
  int get int32Value => getInt32Field(4);
  int get int64Value => getInt64Field(8);
  int get uint8Value => getUint8Field(2);
  int get uint16Value => getUint16Field(2);
  int get uint32Value => getUint32Field(4);
  int get uint64Value => getUint64Field(8);
  double get float32Value => getFloat32Field(4);
  double get float64Value => getFloat64Field(8);
  // text/data/list/struct/interface/anyPointer are all pointer-typed
  // variants of this union, so — like any Cap'n Proto union mixing
  // data-section and pointer-section variants — they share the single
  // pointer slot 0 (only one of them is ever set at a time).
  String? get textValue => getTextField(0);
  Uint8List? get dataValue => getDataField(0);

  // list/struct defaults aren't representable as a simple Dart literal (they
  // can be arbitrarily large/nested), so they're captured as a standalone
  // single-message byte buffer instead — the same representation
  // capnproto_dart's StructReader.getStructFieldWith/list getters accept as
  // their own `defaultValue` parameter (see struct_reader.dart), letting the
  // generator embed them as a plain `Uint8List.fromList([...])` literal.
  Uint8List? get listValue => getAnyPointerAsMessageBytes(0);
  Uint8List? get structValue => getAnyPointerAsMessageBytes(0);
}

// ---- Method @0x9500cce23b334d80 (dataWords=3, ptrWords=5) ----
//
// Ordinal-first layout: @1 codeOrder (UInt16) placed first, then @2/@3 (UInt64).
// A UInt16 at bytes 0-1 prevents the first UInt64 from starting at byte 0,
// so @2 and @3 are pushed to words 1 and 2.
//
// Data section:
//   bytes  0- 1 : codeOrder (UInt16, @1)
//   bytes  8-15 : paramStructType (UInt64/Id, @2)
//   bytes 16-23 : resultStructType (UInt64/Id, @3)
// Pointer section:
//   ptr 0 : name (Text, @0)
//   ptr 1 : annotations (List(Annotation), @4)
//   ptr 2 : paramBrand (Brand, @5)
//   ptr 3 : resultBrand (Brand, @6)
//   ptr 4 : implicitParameters (List(Node.Parameter), @7)
class _MethodReader extends StructReader {
  _MethodReader(super.raw);
  String? get name => getTextField(0);
  int get paramStructTypeId => getUint64Field(8);
  int get resultStructTypeId => getUint64Field(16);
}

// ---- Superclass @0xa9962148649a0168 (dataWords=1, ptrWords=1) ----
//   bytes 0-7 : id (UInt64, @0)
//   ptr 0     : brand (Brand, @1)
class _SuperclassReader extends StructReader {
  _SuperclassReader(super.raw);
  int get id => getUint64Field(0);
}

// ---- Node.Parameter @0xb9521bccf10fa3b1 (dataWords=0, ptrWords=1) ----
//   ptr 0 : name (Text, @0)
class _ParameterReader extends StructReader {
  _ParameterReader(super.raw);
  String? get name => getTextField(0);
}

// ---- CodeGeneratorRequest @0xbfc546f6210ad7ce (dataWords=0, ptrWords=4) ----
//   ptr 0 : nodes (List(Node))
//   ptr 1 : requestedFiles (List(RequestedFile))
//   ptr 2 : capnpVersion
//   ptr 3 : sourceInfo

class _RequestReader extends StructReader {
  _RequestReader(super.raw);

  ListReader<_NodeReader>? get nodes =>
      getStructListFieldWith(0, (r) => _NodeReader(r));
  ListReader<_RequestedFileReader>? get requestedFiles =>
      getStructListFieldWith(1, (r) => _RequestedFileReader(r));
}

// ---- RequestedFile @0xcfea0eb02e810062 (dataWords=1, ptrWords=2) ----
//   bytes 0-7 : id (UInt64, @0)
//   ptr 0     : filename (Text, @1)
//   ptr 1     : imports (List(Import), @2)
class _RequestedFileReader extends StructReader {
  _RequestedFileReader(super.raw);
  int get id => getUint64Field(0);
  String? get filename => getTextField(0);
}

// ---- Minimal factories (needed only to satisfy getRoot API) ----

class _RequestFactory
    extends StructFactory<_RequestReader, _StubBuilder> {
  @override int get dataWords => 0;
  @override int get ptrWords => 4;
  @override _RequestReader fromRawReader(RawStructReader r) => _RequestReader(r);
  @override _StubBuilder fromRawBuilder(RawStructBuilder r) => _StubBuilder(r);
}

class _StubBuilder extends StructBuilder {
  _StubBuilder(super.raw);
  @override StructReader asReader() => throw UnsupportedError('read-only');
}

final _requestFactory = _RequestFactory();

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Parses a raw [CodeGeneratorRequest] message (Cap'n Proto binary framing)
/// into a [CodeGeneratorRequest] model object.
CodeGeneratorRequest readCodeGeneratorRequest(Uint8List bytes) {
  final msg = MessageReader.deserialize(bytes);
  final req = msg.getRoot(_requestFactory);
  return _buildRequest(req);
}

CodeGeneratorRequest _buildRequest(_RequestReader req) {
  final nodeList = req.nodes;
  final fileList = req.requestedFiles;

  final nodes = <SchemaNode>[];
  if (nodeList != null) {
    for (int i = 0; i < nodeList.length; i++) {
      nodes.add(_buildNode(nodeList[i]));
    }
  }

  final files = <RequestedFile>[];
  if (fileList != null) {
    for (int i = 0; i < fileList.length; i++) {
      final f = fileList[i];
      files.add(RequestedFile(
        id: f.id,
        filename: f.filename ?? '',
      ));
    }
  }

  return CodeGeneratorRequest(nodes: nodes, requestedFiles: files);
}

SchemaNode _buildNode(_NodeReader r) {
  final nestedNodes = <SchemaNestedNode>[];
  final nn = r.nestedNodes;
  if (nn != null) {
    for (int i = 0; i < nn.length; i++) {
      nestedNodes.add(SchemaNestedNode(
        name: nn[i].name ?? '',
        id: nn[i].id,
      ));
    }
  }

  final parameters = <String>[];
  final pl = r.parameters;
  if (pl != null) {
    for (int i = 0; i < pl.length; i++) {
      parameters.add(pl[i].name ?? '');
    }
  }

  final body = _buildNodeBody(r);

  return SchemaNode(
    id: r.id,
    displayName: r.displayName ?? '',
    displayNamePrefixLength: r.displayNamePrefixLength,
    scopeId: r.scopeId,
    nestedNodes: nestedNodes,
    body: body,
    parameters: parameters,
  );
}

SchemaNodeBody _buildNodeBody(_NodeReader r) {
  switch (r._unionDisc) {
    case 0: // file
      return const FileBody();
    case 1: // struct
      final fields = <SchemaField>[];
      final fl = r.structFields;
      if (fl != null) {
        for (int i = 0; i < fl.length; i++) {
          fields.add(_buildField(fl[i]));
        }
      }
      return StructBody(
        dataWordCount: r.structDataWordCount,
        pointerCount: r.structPointerCount,
        isGroup: r.structIsGroup,
        discriminantCount: r.structDiscriminantCount,
        discriminantOffset: r.structDiscriminantOffset,
        fields: fields,
      );
    case 2: // enum
      final enumerants = <SchemaEnumerant>[];
      final el = r.enumEnumerants;
      if (el != null) {
        for (int i = 0; i < el.length; i++) {
          enumerants.add(SchemaEnumerant(
            name: el[i].name ?? '',
            codeOrder: el[i].codeOrder,
          ));
        }
      }
      return EnumBody(enumerants: enumerants);
    case 3: // interface
      final methods = <SchemaMethod>[];
      final ml = r.interfaceMethods;
      if (ml != null) {
        for (int i = 0; i < ml.length; i++) {
          methods.add(SchemaMethod(
            name: ml[i].name ?? '',
            ordinal: i,
            paramStructTypeId: ml[i].paramStructTypeId,
            resultStructTypeId: ml[i].resultStructTypeId,
          ));
        }
      }
      final superclassIds = <int>[];
      final sl = r.interfaceSuperclasses;
      if (sl != null) {
        for (int i = 0; i < sl.length; i++) {
          superclassIds.add(sl[i].id);
        }
      }
      return InterfaceBody(methods: methods, superclassIds: superclassIds);
    case 4: // const
      return const ConstBody();
    case 5: // annotation
      return const AnnotationBody();
    default:
      return const FileBody();
  }
}

SchemaField _buildField(_FieldReader r) {
  Object? defaultValue;
  if (r.slotHadExplicitDefault) {
    final dv = r.slotDefaultValue;
    if (dv != null) {
      defaultValue = switch (dv.disc) {
        1 => dv.boolValue,
        2 => dv.int8Value,
        3 => dv.int16Value,
        4 => dv.int32Value,
        5 => dv.int64Value,
        6 => dv.uint8Value,
        7 => dv.uint16Value,
        8 => dv.uint32Value,
        9 => dv.uint64Value,
        10 => dv.float32Value,
        11 => dv.float64Value,
        12 => dv.textValue,
        13 => dv.dataValue,
        14 => dv.listValue,
        15 => dv.uint16Value, // enum stored as uint16
        16 => dv.structValue,
        _ => null,
      };
    }
  }

  final body = r.isSlot
      ? SlotField(
          offset: r.slotOffset,
          type: _buildType(r.slotType),
          hadExplicitDefault: r.slotHadExplicitDefault,
          defaultValue: defaultValue,
        )
      : GroupField(typeId: r.groupTypeId);

  return SchemaField(
    name: r.name ?? '',
    codeOrder: r.codeOrder,
    ordinal: r.ordinal,
    discriminantValue: r.discriminantValue,
    body: body,
  );
}

SchemaType _buildType(_TypeReader? r) {
  if (r == null) return const VoidType();
  switch (r._disc) {
    case 0:  return const VoidType();
    case 1:  return const BoolType();
    case 2:  return const Int8Type();
    case 3:  return const Int16Type();
    case 4:  return const Int32Type();
    case 5:  return const Int64Type();
    case 6:  return const UInt8Type();
    case 7:  return const UInt16Type();
    case 8:  return const UInt32Type();
    case 9:  return const UInt64Type();
    case 10: return const Float32Type();
    case 11: return const Float64Type();
    case 12: return const TextType();
    case 13: return const DataType();
    case 14: return ListType(_buildType(r.listElementType));
    case 15: return EnumRefType(r.typeId);
    case 16:
      final typeArgs16 = _readBrandTypeArgs(r.brand, r.typeId);
      return StructRefType(r.typeId, typeArgs: typeArgs16);
    case 17:
      final typeArgs17 = _readBrandTypeArgs(r.brand, r.typeId);
      return InterfaceRefType(r.typeId, typeArgs: typeArgs17);
    case 18:
      if (r.isTypeParameter) return TypeParameterRefType(r.typeParameterIndex);
      return const AnyPointerType();
    default: return const AnyPointerType();
  }
}

/// Extract the concrete type arguments for [targetScopeId] from a Brand.
/// Returns an empty list if the brand has no binding scope for the target.
List<SchemaType> _readBrandTypeArgs(_BrandReader? brand, int targetScopeId) {
  if (brand == null) return const [];
  final scopes = brand.scopes;
  if (scopes == null) return const [];
  for (int i = 0; i < scopes.length; i++) {
    final scope = scopes[i];
    if (scope.scopeId == targetScopeId && scope.isBind) {
      final bindings = scope.bindings;
      if (bindings == null || bindings.isEmpty) return const [];
      final result = <SchemaType>[];
      for (int j = 0; j < bindings.length; j++) {
        final b = bindings[j];
        result.add(b.isType ? _buildType(b.type) : const AnyPointerType());
      }
      return result;
    }
  }
  return const [];
}
