# External Spec: Serialization Runtime (`capnproto_dart`)

A pure Dart library with no FFI dependencies. Provides encoding, decoding, packed encoding, and streaming for Cap'n Proto messages.

## Message Encoding

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

## Orphan/Adopt

Detach a pointer-typed field's value from its parent (`disown`) and re-attach it
elsewhere (`adopt`) without deep-copying the object content — useful for rearranging
content while building a message, or promoting a nested value to become the root.
When source and destination are in different segments, adoption allocates a two-word
double-far landing pad; the detached object's content bytes are still not copied.

```dart
/// A detached Cap'n Proto object: still allocated in its arena, but nothing
/// currently points to it. Consumed exactly once by an adopt call.
sealed class Orphan {}
final class StructOrphan extends Orphan {}
final class ListOrphan extends Orphan {}   // also covers Text/Data

abstract class StructBuilder {
  /// Detaches the pointer at [ptrIndex] as an Orphan, leaving the field
  /// unset. Returns null if the field was already unset.
  Orphan? disownPointerField(int ptrIndex);

  /// Adopts [orphan] into the pointer at [ptrIndex], replacing whatever was
  /// there. Passing null clears the field.
  void adoptPointerField(int ptrIndex, Orphan? orphan);
}

class MessageBuilder {
  /// Adopts [orphan] as this message's root, replacing whatever's there.
  T adoptRoot<T extends StructBuilder>(StructOrphan orphan, StructFactory<T> factory);
}
```

**Same arena only.** An `Orphan` can only be adopted within the same `MessageBuilder`
it was disowned from — Cap'n Proto pointers are segment-relative within one arena's
segment table, so a true zero-copy move into an unrelated arena isn't representable
without importing every segment the content transitively reaches and rewriting their
segment IDs (at that point it's a different, riskier flavor of the deep copy this
feature exists to avoid — real Cap'n Proto implementations have the same constraint).
Adopting into a different `MessageBuilder` throws `ArgumentError`; to move content
across independent messages, use `copyMessageRootToBuilder`/`copyAnyPointerToNewMessage`
(deep copy, already used internally by the RPC layer).

Capability pointers can't be orphaned (`disownPointerField` throws `UnsupportedError`)
— a capability index is only meaningful together with its message's capability table,
which this serialization-only package has no concept of.

Adopting the same `Orphan` twice throws `StateError`. An Orphan is marked consumed
only after its destination pointer has been installed; if allocation or pointer
encoding throws, it remains available for another adoption attempt.

**Live aliases.** Disowning does not invalidate builders or readers obtained before
the call. `StructOrphan.raw` and `ListOrphan.raw` are also live arena views. Builders
returned after adoption refer to the same memory. Mutating through any such alias
changes what all the others observe. Callers must stop using old aliases when they
want exclusive-ownership semantics; Dart cannot enforce this contract.

## Message Decoding

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

## Base Classes for Generated Code

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

## Primitive Type Mapping

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

**`Int64`/`UInt64` precision on web compile targets**: these map to Dart's built-in
`int`, which is a true 64-bit integer on the Dart VM and AOT-compiled native targets, but
is represented as a JavaScript `number` (an IEEE 754 double) when compiled with dart2js
or DDC (i.e. most `flutter run -d chrome` / web-deployed builds). JS numbers only
represent integers exactly up to ±2^53; values outside that range read or written through
`Int64`/`UInt64` fields on those targets can silently lose precision. This is a property
of Dart's own `int` type on web compile targets, not specific to this library, and is
consistent with how `dart:typed_data`'s `ByteData.getInt64`/`getUint64` (which this
library uses internally) already behaves on those targets. `dart2wasm` targets are
unaffected (they have a true 64-bit `int`). If your application needs exact `Int64`/
`UInt64` precision on dart2js/DDC web builds, avoid relying on values outside
±2^53 (±9,007,199,254,740,992) on those targets specifically.

## Streaming

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

## Dynamic Access and Schema Reflection

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

## Error Handling

All errors thrown by this library are subclasses of `CapnpException`.

```dart
/// Broad classification of why an operation failed — mirrors capnp::ErrorKind.
enum ErrorKind { failed, overloaded, disconnected, unimplemented }

/// Base class for all Cap'n Proto exceptions.
class CapnpException implements Exception {
  final String message;
  final ErrorKind kind;          // defaults to ErrorKind.failed
  final Object? cause;           // the lower-level error this one wraps, if any
  const CapnpException(this.message, {this.kind = ErrorKind.failed, this.cause});
}

/// Thrown when binary data cannot be decoded (e.g., malformed framing, traversal limit exceeded).
class DecodeException extends CapnpException {}

/// Thrown when a schema violation is detected (e.g., required field missing, type mismatch).
class SchemaException extends CapnpException {}
```

`kind` lets callers make semantic decisions (retry? reconnect? give up?) instead of
only having a message string — `overloaded` means retrying later may help,
`disconnected` means the peer/connection is gone, `unimplemented` means the operation
was never supported. It defaults to `failed` everywhere, so existing code that never
passes `kind` is unaffected.

`cause` is the Rust-`.context()` equivalent: when one layer catches a lower-level
error and re-throws with higher-level meaning, it can attach the original via `cause`
instead of discarding it (`toString()` includes it as `... (caused by: ...)` when
present).

In `capnproto_dart_rpc`, `RpcException` (which extends `CapnpException`) round-trips
`kind` over the wire with real Cap'n Proto peers: `rpc.capnp`'s own `Exception.type`
field uses the same 4-value enum in the same order, so a Rust/C++ peer's
`disconnected`/`overloaded`/`unimplemented` classification survives a network hop
intact, and this vat's own `RpcException.kind` (e.g. from a capability's `dispatch`)
is reported back to the peer the same way — not just always "failed".
