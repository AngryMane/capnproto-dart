# `capnproto_dart` Public Symbol Reference

This document catalogs the symbols exported by the public library `package:capnproto_dart/capnproto_dart.dart`.   
In the Consumers column, each label is based on actual references found in this repository — not on hypothetical future callers:

* "Generated code" refers to output produced by `capnpc_dart` — either an actual generated `.capnp.dart` fixture in this repo, or a template in the generator source that emits the symbol (even if no checked-in fixture happens to exercise that branch);  
* "RPC runtime" refers to `capnproto_dart_rpc`'s own implementation (`packages/capnproto_dart_rpc/lib/src/**`, excluding its own tests/benchmarks) — the symbol has no real caller outside it, even though it lives in `capnproto_dart` (so that non-RPC schemas aren't forced to depend on `capnproto_dart_rpc`);  
* "Generated code, RPC runtime" means both of the above apply, with no further evidence of any other caller;  

An "App" label (a genuine downstream application, independent of RPC, that isn't this project's own test/example/benchmark code) does not currently apply to any symbol below — this repository has no such consumer for any part of the public API today. Where a description below still names a realistic use case despite a "Test-only"/"Unreferenced" label, that describes the symbol's intended purpose, not evidence that anything in this repo currently relies on it that way.

## Message 

### Builder and Reader

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `MessageBuilder` | Class | Builds a message and serializes it in normal or packed form. | Generated code, RPC runtime | Create a root via a generated factory and get bytes to send or store. Directly emitted by generated RPC client-side pipeline methods and (via `buildDispatchResult`) generated server-side `build<Method>Results` helpers; also used throughout `capnproto_dart_rpc`'s own message encoding (`rpc_proto.dart`, `capability.dart`). |
| `MessageReader` | Class | Parses normal or packed form and returns a typed/raw root. | Generated code, RPC runtime | Typed decoding of received data and raw reads for RPC (`rpc_payload.dart`, `rpc_proto.dart`); the generator also emits a direct `MessageReader.deserialize(...)` call for struct-typed schema constants. |

### Raw Byte Representation

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `MessageStream` | Class | Reads and writes an async stream of concatenated framed messages. | RPC runtime | Deframing/framing a connection's raw byte stream in the RPC message loop (`two_party_connection.dart`); also usable standalone for a file or socket of concatenated messages, though nothing in this repo does so today. |

### Particular Content 

#### Struct  

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `StructFactory<R, B>` | Abstract class | Defines a struct's layout and the conversion between raw and typed readers/builders. | Generated code, RPC runtime | Factory for each schema struct; reading/writing message roots. Also subclassed/used directly by `capability.dart` and `rpc_payload.dart`. |
| `StructReader` | Abstract class | Base for reading scalar, pointer, list, and capability fields. | Generated code, RPC runtime | Implementing field getters, unions, and group readers; also used by `rpc_proto.dart`. |
| `StructBuilder` | Abstract class | Base for writing fields, initializing nested objects, and orphan operations. | Generated code, RPC runtime | Implementing field setters, `init` methods, and group builders; also used by `rpc_proto.dart`. |
| `RawStructReader` | Class | An untyped, read-only view of a struct inside an arena. | Generated code, RPC runtime | Constructing generated readers and low-level reads; also used by `rpc_proto.dart`/`rpc_payload.dart`. |
| `RawStructBuilder` | Class | An untyped, writable view of a struct inside an arena. | Generated code, RPC runtime | Sharing backing memory between generated and group builders; also used by `rpc_proto.dart`/`rpc_payload.dart`. |

#### List Readers

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `ListReader<T>` | Abstract class | Base for a read-only list providing index access and `Iterable<T>`. | Generated code, RPC runtime | Reading and iterating lists returned by generated fields; also used by `rpc_proto.dart` (transform-path lists). |
| `NestedListReader<T>` | Class | A reader that lazily resolves a list-of-lists. | Generated code | Implementing `List(List(T))` accessors. |
| `voidListFromRaw`, `boolListFromRaw` | Function | Converts a raw list into a Void/Bool reader. | Generated code | Reading `List(Void)`/`List(Bool)`. |
| `int8ListFromRaw`, `int16ListFromRaw`, `int32ListFromRaw`, `int64ListFromRaw` | Function | Converts a raw list into a signed-integer reader. | Generated code | Reading signed-integer lists. |
| `uint8ListFromRaw`, `uint16ListFromRaw`, `uint32ListFromRaw`, `uint64ListFromRaw` | Function | Converts a raw list into an unsigned-integer reader. | Generated code | Reading unsigned-integer lists. |
| `float32ListFromRaw`, `float64ListFromRaw` | Function | Converts a raw list into a floating-point reader. | Generated code | Reading float lists. |
| `textListFromRaw`, `dataListFromRaw` | Function | Converts a raw pointer list into a Text/Data reader. | Generated code | Reading Text/Data lists. |
| `enumListFromRaw` | Function | Builds an enum reader from a uint16 list and an ordinal callback. | Generated code | Reading schema-enum lists. |
| `structListFromRaw` | Function | Builds a typed struct reader from a composite list and a factory. | Generated code | Reading struct lists. |
| `TypedCapabilityListReader<T>` | Class | Returns a typed capability from the capability table. | Generated code | Converting interface lists into client/stub types. Emitted by the generator's template for `List(Interface)` fields; none of this repo's checked-in schemas happen to declare one, so no fixture currently contains it. |

#### List Builders

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `ListBuilder<T>` | Abstract class | Defines a typed list's length and indexed read/write. | Generated code, RPC runtime | Writing to lists returned by generated `init...` methods; also used by `rpc_proto.dart`. |
| `NestedListBuilder<T>` | Class | Initializes the inner list of a list-of-lists. | Generated code | Building `List(List(T))`. |
| `voidListBuilderFromRaw`, `boolListBuilderFromRaw` | Function | Converts a raw list into a Void/Bool builder. | Generated code | Building Void/Bool lists. |
| `int8ListBuilderFromRaw`, `int16ListBuilderFromRaw`, `int32ListBuilderFromRaw`, `int64ListBuilderFromRaw` | Function | Converts a raw list into a signed-integer builder. | Generated code | Building signed-integer lists. |
| `uint8ListBuilderFromRaw`, `uint16ListBuilderFromRaw`, `uint32ListBuilderFromRaw`, `uint64ListBuilderFromRaw` | Function | Converts a raw list into an unsigned-integer builder. | Generated code | Building unsigned-integer lists. |
| `float32ListBuilderFromRaw`, `float64ListBuilderFromRaw` | Function | Converts a raw list into a floating-point builder. | Generated code | Building float lists. |
| `textListBuilderFromRaw`, `dataListBuilderFromRaw` | Function | Converts a raw pointer list into a Text/Data builder. | Generated code | Building Text/Data lists. |
| `enumListBuilderFromRaw` | Function | Builds a builder from a raw uint16 list and an enum-to-ordinal callback. | Generated code | Building enum lists. |
| `structListBuilderFromRaw` | Function | Builds a typed builder from a raw composite list and a callback. | Generated code | Building struct lists. |
| `capabilityListBuilderFromRaw` | Function | Converts a raw pointer list into a capability-index builder. | Generated code | Implementing capability-list accessors. Emitted by the generator's template for `List(Interface)` builder fields; no checked-in fixture currently exercises it. |

#### Dynamic Type and Schema Reflection

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `DynamicStructReader` | Class | A struct reader that needs no schema class. | RPC runtime | Reading structs via reflection metadata. `RpcPayload.getDynamic()` uses it directly. |
| `AnnotationInfo` | Class | Represents an annotation's node id and applied value. | Generated code | Interpreting custom annotations. |
| `StructSchemaInfo` | Class | Represents a struct's layout, fields, unions, and type parameters. | Generated code | Dynamic access, text format, and schema inspectors. |
| `FieldSchemaInfo` | Class | Represents a field's name, order, discriminant, and body. | Generated code | Field lookup and union discrimination. |
| `SlotFieldSchemaInfo`, `GroupFieldSchemaInfo` | Class | Represents a slot's offset/type/default, or a group's type id. | Generated code | Dynamic field access and resolving group schemas. |
| `EnumSchemaInfo`, `EnumerantSchemaInfo` | Class | Represents an enum and its values' names, order, and wire ordinal. | Generated code | Ordinal/name conversion and text format. |
| `InterfaceSchemaInfo`, `MethodSchemaInfo` | Class | Represents interface inheritance, methods, and parameter/result type ids. | Generated code | Constructed as static metadata for every schema interface. Despite the name, `capnproto_dart_rpc` does not read these for dispatch — RPC method calls go through the generated client/server classes directly, not schema reflection. |
| `PrimitiveTypeSchemaInfo` | Class | Represents a primitive type's name. | Generated code | Dynamic handling of scalars, Text, Data, and Void. |
| `AnyPointerTypeSchemaInfo` | Class | Represents the AnyPointer type. | Generated code | Dynamic handling of arbitrary pointers. |
| `TypeParameterSchemaInfo` | Class | Represents a generic type-parameter index. | Generated code | Mapping runtime codecs to schema parameters. |
| `ListTypeSchemaInfo` | Class | Represents a list's element type. | Generated code | Dynamic encode/decode of nested lists. |
| `StructRefTypeSchemaInfo`, `EnumRefTypeSchemaInfo`, `InterfaceRefTypeSchemaInfo` | Class | Represents a referenced node's type id and type arguments. | Generated code | Resolving the referenced schema from a registry. |

#### Pointer

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `WirePointer` | Sealed class | Abstract representation for decoding/encoding an 8-byte wire pointer. | RPC runtime | Inspecting a dispatch result's pointer slot to confirm it holds a capability before resolving it. Not referenced by any generated code. |
| `CapabilityPointer` | Class | A wire pointer holding a capability-table index. | RPC runtime | Extracting the capability-table index from a resolved pointer slot. |
| `AnyPointerCodec<T>` | Abstract interface | Contract for encoding/decoding a generic type parameter to/from AnyPointer. | Generated code, RPC runtime | Supplying a runtime codec to generic RPC helpers; implemented by generated code for typed generic fields and used directly by `capability_any_pointer_codec.dart`. |
| `AnyPointerReader` | Class | A read-only AnyPointer view that holds a capability table. | Generated code, RPC runtime | Reinterpreting as a message, struct, list, or capability; used throughout `capability_any_pointer_codec.dart` and `rpc_proto.dart`. |
| `AnyPointerBuilder` | Class | A writable AnyPointer field view. | Generated code, RPC runtime | Setting a pointer slot to a message, struct/list, or capability; used throughout `capability.dart`, `rpc_proto.dart`, and `two_party_connection.dart`. |

## Errors
| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `CapnpException` | Class | Base exception for all Cap'n Proto processing. Holds a cause and an error kind. | RPC runtime | Propagating serialization/RPC failures in a common shape; `RpcException` (`rpc_exception.dart`) subclasses it and it's checked directly in `two_party_connection.dart`. |
| `ErrorKind` | Enum | Four failure categories. | RPC runtime | Correlating failures with an RPC peer's classification and deciding things like retryability. `capnproto_dart`'s own exceptions (e.g. `DecodeException`) never set anything but the default `failed`. |

## Usage Boundaries

- For RPC server implementations, prefer the generated `build<Method>Results` helper (backed by `capnproto_dart_rpc`'s `buildDispatchResult`) over constructing a `MessageBuilder` by hand — it covers the common case of building a fresh results struct and wrapping it in a `DispatchResult`.
- The base classes intended for generated code, and the `...FromRaw` functions, also serve as extension points for a custom generator or runtime integration.
- Orphan adoption is only valid within the same `MessageBuilder`/arena.
- Schema Reflection metadata underlies both the Dynamic API and Text Format; today both of those are exercised only by this package's own tests, not by `capnproto_dart_rpc` or any other code in this repo.
- MessageStream/ErrorKind/WirePointer/CapabilityPointer/CapnpException are public only because capnproto_dart_rpc needs them and must not force non-RPC schemas to depend on it.
- Several symbols (`RawListReader`, `capabilityListFromRaw`, `canonicalizeMessage`, `StructReaderAnyPointerCodec`, `SchemaInfo`, `TypeSchemaInfo`, `FieldBodySchemaInfo`) have no evidenced caller anywhere in this repo beyond (at most) their own definition — they may be worth revisiting as candidates for removal, or their absence of test coverage may be worth addressing, independent of this document.
