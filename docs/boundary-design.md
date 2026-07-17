# Boundary Design

This document defines the external interfaces provided by all three components.

---

## Component 1: CLI Tool (`capnpc-dart`)

The CLI Tool is implemented as a plugin for the official `capnp` compiler. Schema parsing is delegated to the official compiler; this component handles only code generation and compatibility checking. The implementation language is not restricted to Dart.

### `capnpc-dart` — Code Generator Plugin

Invoked by the `capnp` compiler via its plugin mechanism. Users do not call this binary directly.

```
# User-facing invocation (capnp compiler delegates to capnpc-dart)
capnp compile -o dart <schema.capnp...>
```

**Input**: `CodeGeneratorRequest` message in Cap'n Proto binary format, received via **stdin**  
**Output**: Generated `.dart` source files written to disk  
**Exit code**: `0` on success, non-zero on error

#### Compatibility check mode

```
capnp compile -o dart:check=<old.capnp> <new.capnp>
```

**Input**: `CodeGeneratorRequest` for the new schema via **stdin**; old schema path provided as the `check` option  
**Output**: List of incompatible changes printed to stdout  
**Exit code**: `0` if compatible, `1` if incompatible changes are detected, `2` on error

### Dependency

`capnpc-dart` requires the official `capnp` compiler to be installed on the developer's machine. It is used at build time only and is never shipped with the Flutter/Dart application.

---

## Component 2: Serialization Runtime (`capnproto_dart`)

A pure Dart library with no FFI dependencies. Provides encoding, decoding, packed encoding, and streaming for Cap'n Proto messages.

### Message Encoding

```dart
/// Entry point for building a new Cap'n Proto message.
class MessageBuilder {
  /// Initializes and returns the root struct of the message.
  T initRoot<T extends StructBuilder>(StructFactory<T> factory);

  /// Serializes the message into standard Cap'n Proto framing format.
  Uint8List serialize();

  /// Serializes the message using packed encoding (zero-byte compression).
  Uint8List serializePacked();
}
```

### Message Decoding

```dart
/// Configuration options for reading a Cap'n Proto message.
class MessageReaderOptions {
  /// Maximum number of 8-byte words allowed to be traversed.
  /// Guards against amplification attacks. Default: 8 * 1024 * 1024 (= 64 MiB).
  final int traversalLimitInWords;

  /// Maximum pointer nesting depth allowed.
  /// Guards against stack overflow. Default: 64.
  final int nestingLimit;

  /// Maximum number of segments a message's framing header may declare.
  /// Guards against a small message claiming an enormous segment count.
  /// Default: 512.
  final int maxSegments;

  const MessageReaderOptions({
    this.traversalLimitInWords = 8 * 1024 * 1024,
    this.nestingLimit = 64,
    this.maxSegments = 512,
  });
}

/// Entry point for reading an existing Cap'n Proto message.
class MessageReader {
  /// Deserializes a message from standard Cap'n Proto framing format.
  static MessageReader deserialize(Uint8List bytes,
      [MessageReaderOptions options = const MessageReaderOptions()]);

  /// Deserializes a message from packed encoding.
  static MessageReader deserializePacked(Uint8List bytes,
      [MessageReaderOptions options = const MessageReaderOptions()]);

  /// Returns the root struct of the message.
  /// [capabilities] resolves interface pointers for RPC callers;
  /// plain serialization callers can omit it.
  T getRoot<T extends StructReader>(StructFactory<T> factory,
      {List<Object?> capabilities = const []});

  /// Returns the [canonical](https://capnproto.org/encoding.html#canonicalization)
  /// encoding of this message: struct data/pointer sections are trimmed of
  /// trailing default-valued words, and struct lists are re-packed to the
  /// smallest uniform element size. Throws [DecodeException] if the message
  /// contains a capability pointer anywhere.
  Uint8List canonicalize();
}
```

### Base Classes for Generated Code

Generated Dart code subclasses these types to provide typed field access.

```dart
/// Read-only view of a Cap'n Proto struct.
/// Generated subclasses expose getX() accessors for each field.
abstract class StructReader {}

/// Mutable builder for a Cap'n Proto struct.
/// Generated subclasses expose the following method patterns per field:
///   T    getX()        — get current value (pointer fields return reader)
///   void setX(T value) — set a primitive or enum field
///   B    initX()       — allocate and return a builder for a pointer field
///   bool hasX()        — true if a pointer field is set (non-null)
abstract class StructBuilder {
  StructReader asReader();
}

/// Factory used by MessageBuilder/MessageReader to create typed struct instances.
abstract class StructFactory<R extends StructReader, B extends StructBuilder> {
  R fromRawReader(RawStructReader raw);
  B fromRawBuilder(RawStructBuilder raw);
}

/// Read-only view of a Cap'n Proto list.
abstract class ListReader<T> implements Iterable<T> {
  int get length;
  T operator [](int index);
}

/// Mutable builder for a Cap'n Proto list.
abstract class ListBuilder<T> {
  int get length;
  T operator [](int index);
  void operator []=(int index, T value);
}
```

### Primitive Type Mapping

| Cap'n Proto type | Dart type |
|---|---|
| `Bool` | `bool` |
| `Int8` / `Int16` / `Int32` / `Int64` | `int` |
| `UInt8` / `UInt16` / `UInt32` / `UInt64` | `int` |
| `Float32` / `Float64` | `double` |
| `Text` | `String` |
| `Data` | `Uint8List` |
| `Void` | N/A (omitted from generated API) |
| Enum | Dart `enum` |
| Union | Dart `sealed class` |

### Streaming

```dart
/// Utilities for sending and receiving sequences of Cap'n Proto messages over a byte stream.
class MessageStream {
  /// Wraps a byte stream and emits one MessageReader per framed message.
  static Stream<MessageReader> deserializeStream(Stream<Uint8List> bytes,
      [MessageReaderOptions options = const MessageReaderOptions()]);

  /// Wraps a stream of MessageBuilders and emits serialized bytes per message.
  static Stream<Uint8List> serializeStream(Stream<MessageBuilder> messages);
}
```

### Dynamic Access and Schema Reflection

For cases where the concrete struct type isn't known at compile time — inspecting an
`AnyPointer` field, or the RPC layer resolving `Payload.content` — the runtime provides
schema-less read/write access built on metadata that `capnpc-dart` emits alongside each
generated type.

```dart
/// Generated code emits a `const SchemaInfo` per struct/enum/interface,
/// exposed via `StructFactory.schema`.
sealed class SchemaInfo {}
final class StructSchemaInfo extends SchemaInfo {
  FieldSchemaInfo? fieldByName(String name);
}
final class EnumSchemaInfo extends SchemaInfo {}
final class InterfaceSchemaInfo extends SchemaInfo {
  MethodSchemaInfo? methodByName(String name);
}

/// Read-only view of an AnyPointer field.
final class AnyPointerReader {
  DynamicStructReader? asDynamicStruct();
  DynamicListReader? asDynamicList();
  ListReader<String?>? asTextList();
  ListReader<Uint8List?>? asDataList();
  Object? asCapability();
}

/// Mutable view of an AnyPointer field.
final class AnyPointerBuilder { /* mirrors AnyPointerReader, plus init*/set* methods */ }

/// Schema-driven struct/list views: fields are addressed via [SchemaInfo]
/// rather than generated per-field getters.
final class DynamicStructReader extends StructReader {}
final class DynamicListReader {}
final class DynamicStructBuilder extends StructBuilder {}
final class DynamicListBuilder {}
```

### Error Handling

All errors thrown by this library are subclasses of `CapnpException`.

```dart
/// Base class for all Cap'n Proto exceptions.
class CapnpException implements Exception {
  final String message;
  const CapnpException(this.message);
}

/// Thrown when binary data cannot be decoded (e.g., malformed framing, traversal limit exceeded).
class DecodeException extends CapnpException {}

/// Thrown when a schema violation is detected (e.g., required field missing, type mismatch).
class SchemaException extends CapnpException {}
```

---

## Component 3: RPC Runtime (`capnproto_dart_rpc`)

A pure Dart library with no FFI dependencies. Depends on Component 2 (`capnproto_dart`) for message encoding; only needed by applications that use RPC.

Implements a **Cap'n Proto RPC Level 1 subset**: object-capability references and promise pipelining
in two-party connections. The following Level 1 features are **not** implemented:
- `Resolve` and `Disembargo` messages sent by the Dart vat (only received/processed when sent by a peer)
- Three-party handoff (required for full Level 1 compliance)

Level 2 and above (persistent capabilities) are out of scope.

### Core RPC types

```dart
/// Base class for all Cap'n Proto capabilities (remote object references).
/// A capability both designates an object and confers permission to call it.
abstract class Capability {
  Future<void> dispose();
}

/// Manages an RPC connection to a remote peer.
abstract class RpcConnection {
  /// Returns the bootstrap capability offered by the remote peer.
  T bootstrap<T extends Capability>(CapabilityFactory<T> factory);

  /// Closes the connection and releases all associated capabilities.
  Future<void> close();
}

/// Factory for wrapping a raw RPC connection as a typed capability.
abstract class CapabilityFactory<T extends Capability> {
  T fromConnection(RpcConnection connection);
}

/// Entry point for establishing and serving RPC connections.
class RpcSystem {
  /// Connects to a remote Cap'n Proto RPC server.
  ///
  /// [onDisposeError] observes a capability's `dispose()` throwing during
  /// internal cleanup — such a failure never blocks or fails the
  /// surrounding operation, so this is the only way to see it.
  static Future<RpcConnection> connect(Uri address,
      {void Function(Object error, StackTrace stackTrace)? onDisposeError});

  /// Starts a server and serves the given bootstrap capability to incoming clients.
  static Future<RpcServer> serve(Uri address, Capability bootstrap,
      {void Function(Object error, StackTrace stackTrace)? onDisposeError});
}

/// Represents a running Cap'n Proto RPC server.
abstract class RpcServer {
  Future<void> close();
}
```

### Promise Pipelining

Dart's `Future<T>` naturally supports promise pipelining. Generated client stubs return
`Future<T>` where `T` is itself a capability, enabling callers to chain calls without
waiting for intermediate results to resolve:

```dart
// Without pipelining: 2 round-trips
final fooResult = await client.getFoo();
final barResult = await fooResult.getBar();

// With pipelining: 1 round-trip (calls are sent immediately)
final barResult = await client.getFoo().then((foo) => foo.getBar());
```

The runtime sends both calls to the server in a single round-trip when the intermediate
result is a capability.

### Error Handling

RPC errors extend `CapnpException` (defined in Component 2, `capnproto_dart`).

```dart
/// Thrown when an RPC call fails (e.g., connection lost, remote exception).
class RpcException extends CapnpException {}
```

---

## Generated Code Interface

`capnpc-dart` generates one `.dart` file per `.capnp` file. The generated code provides
typed accessors built on top of the Serialization Runtime base classes.

### Example: Schema

```capnp
struct Person {
  name @0 :Text;
  age  @1 :UInt32;
  address @2 :Address;
}

struct Address {
  city @0 :Text;
}
```

### Example: Generated Dart Code

```dart
// Generated — do not edit by hand.

import 'package:capnproto_dart/capnproto_dart.dart';

// ignore_for_file: annotate_overrides

final class PersonReader extends StructReader {
  String      get name    => ...;
  int         get age     => ...;
  AddressReader get address => ...;
  bool        hasAddress()  => ...;
}

final class PersonBuilder extends StructBuilder {
  String      get name      => ...;
  set name(String value)    => ...;
  int         get age       => ...;
  set age(int value)        => ...;
  AddressReader get address => ...;
  AddressBuilder initAddress() => ...;
  bool        hasAddress()     => ...;

  @override
  PersonReader asReader() => ...;
}

final personFactory = _PersonFactory();
```
