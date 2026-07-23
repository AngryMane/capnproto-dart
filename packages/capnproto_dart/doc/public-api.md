# `capnproto_dart` Public Symbol Reference

This document catalogs the symbols exported by the public library `package:capnproto_dart/capnproto_dart.dart`.   
In the Consumers column,  

* "Generated code" refers to output produced by `capnpc_dart`;  
* "App" refers to applications and tools that consume the generated code, independent of RPC;  
* "RPC runtime" refers to `capnproto_dart_rpc`'s own implementation — the symbol has no real caller outside it, even though it lives in `capnproto_dart` (so that non-RPC schemas aren't forced to depend on `capnproto_dart_rpc`);  
* "Both" means "Generated code" and "App" together. A symbol also used by the RPC runtime, but not primarily so, keeps its "App"/"Both" label rather than listing "RPC runtime" as well.   

## Message 

### Builder and Reader

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `MessageBuilder` | Class | Builds a message and serializes it in normal or packed form. | App | Create a root via a generated factory and get bytes to send or store. |
| `MessageReader` | Class | Parses normal or packed form and returns a typed/raw root. | App | Typed decoding of received data, canonicalization, and raw reads for RPC. |
| `MessageReaderOptions` | Class | Holds limits on traversal, nesting depth, and segment count. | App | Bounding amplification and oversized framing headers from untrusted input. |
| `canonicalizeMessage` | Function | Converts a framed message into a single canonical segment with no framing. | App | Using a unique encoding for hashing, signing, or value-equality comparisons. |

### Raw Byte Representation

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `MessageStream` | Class | Reads and writes an async stream of concatenated framed messages. | RPC runtime | Deframing/framing a connection's raw byte stream in the RPC message loop; also usable standalone for a file or socket of concatenated messages, though nothing in this repo does so today. |

### Particular Content 

#### Struct  

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `StructFactory<R, B>` | Abstract class | Defines a struct's layout and the conversion between raw and typed readers/builders. | Generated code | Factory for each schema struct; reading/writing message roots. |
| `StructReader` | Abstract class | Base for reading scalar, pointer, list, and capability fields. | Generated code | Implementing field getters, unions, and group readers. |
| `StructBuilder` | Abstract class | Base for writing fields, initializing nested objects, and orphan operations. | Generated code | Implementing field setters, `init` methods, and group builders. |
| `RawStructReader` | Class | An untyped, read-only view of a struct inside an arena. | Generated code | Constructing generated readers and low-level reads. |
| `RawListReader` | Class | A view representing a list's position, element count, and layout inside an arena. | Generated code | Converting a raw list into a typed reader. |
| `RawStructBuilder` | Class | An untyped, writable view of a struct inside an arena. | Generated code | Sharing backing memory between generated and group builders. |

#### List Readers

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `ListReader<T>` | Abstract class | Base for a read-only list providing index access and `Iterable<T>`. | Both | Reading and iterating lists returned by generated fields. |
| `NestedListReader<T>` | Class | A reader that lazily resolves a list-of-lists. | Generated code | Implementing `List(List(T))` accessors. |
| `voidListFromRaw`, `boolListFromRaw` | Function | Converts a raw list into a Void/Bool reader. | Generated code | Reading `List(Void)`/`List(Bool)`. |
| `int8ListFromRaw`, `int16ListFromRaw`, `int32ListFromRaw`, `int64ListFromRaw` | Function | Converts a raw list into a signed-integer reader. | Generated code | Reading signed-integer lists. |
| `uint8ListFromRaw`, `uint16ListFromRaw`, `uint32ListFromRaw`, `uint64ListFromRaw` | Function | Converts a raw list into an unsigned-integer reader. | Generated code | Reading unsigned-integer lists. |
| `float32ListFromRaw`, `float64ListFromRaw` | Function | Converts a raw list into a floating-point reader. | Generated code | Reading float lists. |
| `textListFromRaw`, `dataListFromRaw` | Function | Converts a raw pointer list into a Text/Data reader. | Generated code | Reading Text/Data lists. |
| `enumListFromRaw` | Function | Builds an enum reader from a uint16 list and an ordinal callback. | Generated code | Reading schema-enum lists. |
| `structListFromRaw` | Function | Builds a typed struct reader from a composite list and a factory. | Generated code | Reading struct lists. |
| `CapabilityListReader` | Class | Reads a capability-pointer list as table indices. | Generated code | Manipulating wire indices of RPC capability lists. |
| `TypedCapabilityListReader<T>` | Class | Returns a typed capability from the capability table. | Generated code | Converting interface lists into client/stub types. |
| `capabilityListFromRaw` | Function | Converts a raw pointer list into a capability-index reader. | Generated code | Implementing capability-list accessors. |

#### List Builders

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `ListBuilder<T>` | Abstract class | Defines a typed list's length and indexed read/write. | Both | Writing to lists returned by generated `init...` methods. |
| `NestedListBuilder<T>` | Class | Initializes the inner list of a list-of-lists. | Generated code | Building `List(List(T))`. |
| `voidListBuilderFromRaw`, `boolListBuilderFromRaw` | Function | Converts a raw list into a Void/Bool builder. | Generated code | Building Void/Bool lists. |
| `int8ListBuilderFromRaw`, `int16ListBuilderFromRaw`, `int32ListBuilderFromRaw`, `int64ListBuilderFromRaw` | Function | Converts a raw list into a signed-integer builder. | Generated code | Building signed-integer lists. |
| `uint8ListBuilderFromRaw`, `uint16ListBuilderFromRaw`, `uint32ListBuilderFromRaw`, `uint64ListBuilderFromRaw` | Function | Converts a raw list into an unsigned-integer builder. | Generated code | Building unsigned-integer lists. |
| `float32ListBuilderFromRaw`, `float64ListBuilderFromRaw` | Function | Converts a raw list into a floating-point builder. | Generated code | Building float lists. |
| `textListBuilderFromRaw`, `dataListBuilderFromRaw` | Function | Converts a raw pointer list into a Text/Data builder. | Generated code | Building Text/Data lists. |
| `enumListBuilderFromRaw` | Function | Builds a builder from a raw uint16 list and an enum-to-ordinal callback. | Generated code | Building enum lists. |
| `structListBuilderFromRaw` | Function | Builds a typed builder from a raw composite list and a callback. | Generated code | Building struct lists. |
| `CapabilityListBuilder` | Class | Reads/writes a capability-table index into a pointer list. | Generated code | Building RPC capability lists. |
| `capabilityListBuilderFromRaw` | Function | Converts a raw pointer list into a capability-index builder. | Generated code | Implementing capability-list accessors. |

#### Dynamic Type and Schema Reflection

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `DynamicStructReader`, `DynamicStructBuilder` | Class | A struct reader/builder that needs no schema class. | App | Reading/writing structs via reflection metadata. |
| `DynamicListReader`, `DynamicListBuilder` | Class | A schema-less list view operating on runtime layout. | App | List operations for inspectors, text format, and generic codecs. |
| `encodeText` | Function | Converts a serialized message to text format. | App | Debug output, CLIs, and snapshots. |
| `decodeText` | Function | Converts text format into framed message bytes. | App | Building fixtures, CLI input, and test data. |
| `SchemaInfo` | Sealed class | Base metadata holding a node id, name, and annotations. | Both | Identifying schema nodes. |
| `AnnotationInfo` | Class | Represents an annotation's node id and applied value. | Both | Interpreting custom annotations. |
| `StructSchemaInfo` | Class | Represents a struct's layout, fields, unions, and type parameters. | Both | Dynamic access, text format, and schema inspectors. |
| `FieldSchemaInfo` | Class | Represents a field's name, order, discriminant, and body. | Both | Field lookup and union discrimination. |
| `FieldBodySchemaInfo` | Sealed class | Common base for slot/group fields. | Both | Classifying field metadata by kind. |
| `SlotFieldSchemaInfo`, `GroupFieldSchemaInfo` | Class | Represents a slot's offset/type/default, or a group's type id. | Both | Dynamic field access and resolving group schemas. |
| `EnumSchemaInfo`, `EnumerantSchemaInfo` | Class | Represents an enum and its values' names, order, and wire ordinal. | Both | Ordinal/name conversion and text format. |
| `InterfaceSchemaInfo`, `MethodSchemaInfo` | Class | Represents interface inheritance, methods, and parameter/result type ids. | Both | RPC reflection and method dispatch. |
| `TypeSchemaInfo` | Sealed class | Common base for type information in reflection. | Both | Type branching in dynamic codecs. |
| `PrimitiveTypeSchemaInfo` | Class | Represents a primitive type's name. | Both | Dynamic handling of scalars, Text, Data, and Void. |
| `AnyPointerTypeSchemaInfo` | Class | Represents the AnyPointer type. | Both | Dynamic handling of arbitrary pointers. |
| `TypeParameterSchemaInfo` | Class | Represents a generic type-parameter index. | Both | Mapping runtime codecs to schema parameters. |
| `ListTypeSchemaInfo` | Class | Represents a list's element type. | Both | Dynamic encode/decode of nested lists. |
| `StructRefTypeSchemaInfo`, `EnumRefTypeSchemaInfo`, `InterfaceRefTypeSchemaInfo` | Class | Represents a referenced node's type id and type arguments. | Both | Resolving the referenced schema from a registry. |
| `SchemaRegistry` | Type alias | A map from node id to `SchemaInfo`. | App | Passing a set of schemas to text format or dynamic processing. |
| `schemaRegistryOf` | Function | Builds a registry from an iterable of `SchemaInfo`. | App | Looking up node ids in generated metadata. |

#### Pointer

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `WirePointer` | Sealed class | Abstract representation for decoding/encoding an 8-byte wire pointer. | RPC runtime | Inspecting a dispatch result's pointer slot to confirm it holds a capability before resolving it. Not referenced by any generated code. |
| `CapabilityPointer` | Class | A wire pointer holding a capability-table index. | RPC runtime | Extracting the capability-table index from a resolved pointer slot. |
| `AnyPointerCodec<T>` | Abstract interface | Contract for encoding/decoding a generic type parameter to/from AnyPointer. | Both | Supplying a runtime codec to generic RPC helpers. |
| `MessageAnyPointerCodec` | Class | A codec that treats a serialized message as an AnyPointer value. | App | Passing around a generic payload held as raw bytes. |
| `StructReaderAnyPointerCodec<R, B>` | Class | An AnyPointer decode codec for typed struct readers. | App | Turning a generic result into a typed reader. |
| `AnyPointerReader` | Class | A read-only AnyPointer view that holds a capability table. | Both | Reinterpreting as a message, struct, list, or capability. |
| `AnyPointerBuilder` | Class | A writable AnyPointer field view. | Both | Setting a pointer slot to a message, struct/list, or capability. |

## Orphans

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `Orphan` | Sealed class | Base type for an object detached from a pointer. | App | Zero-copy moves within the same arena via disown/adopt. |
| `StructOrphan` | Class | Holds a detached struct. | App | Moving a struct to another field/root. |
| `ListOrphan` | Class | Holds a detached list. | App | Moving a list, Text, or Data to another pointer slot. |

## Errors
| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `CapnpException` | Class | Base exception for all Cap'n Proto processing. Holds a cause and an error kind. | App | Propagating serialization/RPC failures in a common shape. |
| `DecodeException` | Class | Represents malformed wire data or an exceeded decode limit. | App | Handling parse errors from external input. |
| `ErrorKind` | Enum | Four failure categories. | RPC runtime | Correlating failures with an RPC peer's classification and deciding things like retryability. `capnproto_dart`'s own exceptions (e.g. `DecodeException`) never set anything but the default `failed`. |

## Usage Boundaries

- A typical application mainly uses `MessageBuilder`/`MessageReader` together with generated factories, readers, and builders.
- The base classes intended for generated code, and the `...FromRaw` functions, also serve as extension points for a custom generator or runtime integration.
- Orphan adoption is only valid within the same `MessageBuilder`/arena.
- Schema Reflection metadata underlies both the Dynamic API and Text Format; a typical app never touches it unless it opts into one of those.
- MessageStream/ErrorKind/WirePointer/CapabilityPointer are public only because capnproto_dart_rpc needs them and must not force non-RPC schemas to depend on it — a plain app has no reason to use them directly.

