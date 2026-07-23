# capnproto_dart

Pure Dart runtime for Cap'n Proto serialization, packed encoding,
canonicalization, and framed message streams. It has no FFI dependency.

This package reads and writes messages. Typed readers and builders are
generated from `.capnp` schemas by the separate
[`capnpc_dart`](https://pub.dev/packages/capnpc_dart) package.

## Install

```sh
dart pub add capnproto_dart
dart pub global activate capnpc_dart
```

The code generator also requires the official `capnp` executable. See the
[`capnpc_dart` README](https://pub.dev/packages/capnpc_dart) for setup and
generation commands.

## Build and read a message

Given generated code at `lib/src/generated/hello.capnp.dart`:

```dart
import 'package:capnproto_dart/capnproto_dart.dart';
import 'src/generated/hello.capnp.dart';

void main() {
  final builder = MessageBuilder();
  final greeting = builder.initRoot(greetingFactory);
  greeting.name = 'World';

  final bytes = builder.serialize();
  final reader = MessageReader.deserialize(bytes);
  final decoded = reader.getRoot(greetingFactory);

  print(decoded.name); // World
}
```

The generated factory is named `<structName>Factory`, using lower camel case.

## Packed encoding

Packed encoding compresses runs of zero and verbatim words without changing
the message content:

```dart
final packed = builder.serializePacked();
final reader = MessageReader.deserializePacked(packed);
final greeting = reader.getRoot(greetingFactory);
```

Malformed input and configured size-limit violations throw `DecodeException`.
Use `MessageReaderOptions` to configure traversal, nesting, and segment
limits when reading untrusted data. Packed decoding derives its expansion limit
from the traversal limit.

## Message streams

`MessageStream` handles multiple standard-framed messages concatenated on a
byte stream. Input chunks may end anywhere inside a frame.

```dart
await for (final reader in MessageStream.deserializeStream(socketBytes)) {
  final greeting = reader.getRoot(greetingFactory);
  print(greeting.name);
}

final Stream<Uint8List> output =
    MessageStream.serializeStream(messageBuilders);
```

## Supported features

- Single- and multi-segment messages
- Structs, lists, enums, unions, groups, generics, and constants
- Far and double-far pointers
- Packed encoding and decoding
- Canonicalization
- Framed message streams
- Schema reflection, dynamic access, and text format
- Orphans and zero-copy adoption where the wire layout permits it

RPC capabilities and network transports are provided by
[`capnproto_dart_rpc`](https://pub.dev/packages/capnproto_dart_rpc). Code
generation is provided by [`capnpc_dart`](https://pub.dev/packages/capnpc_dart).

See the [serialization guide](https://angrymane.github.io/capnproto-dart/howto/serialization)
and [API documentation](https://pub.dev/documentation/capnproto_dart/latest/)
for the full contract.
