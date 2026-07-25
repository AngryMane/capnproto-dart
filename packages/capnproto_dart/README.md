# capnproto_dart

Reads and writes Cap'n Proto messages in Dart — this is the package that
turns your `.capnp` schema types into Dart objects you can build, and turns
those objects back into bytes you can send or save.

If you're building an app that only talks to other processes over RPC, you
usually don't need to depend on this package directly — install
[`capnproto_dart_rpc`](https://pub.dev/packages/capnproto_dart_rpc) instead,
which already includes everything here. Use `capnproto_dart` directly when
you're reading or writing Cap'n Proto messages without RPC, e.g. saving state
to a file or sending messages over your own transport.

## How the pieces fit together

- [`capnpc_dart`](https://pub.dev/packages/capnpc_dart) is a compiler plugin
  that turns your `.capnp` schema into Dart classes.
- `capnproto_dart` (this package) is the runtime those generated classes use
  to serialize and deserialize.
- [`capnproto_dart_rpc`](https://pub.dev/packages/capnproto_dart_rpc) adds
  networked RPC (calling methods on a remote object) on top of both.

## Install

Add this package and the code-generation builder to `pubspec.yaml`:

```yaml
dependencies:
  capnproto_dart: ^0.1.0

dev_dependencies:
  build_runner: ^2.4.13
  capnpc_dart_builder: ^0.1.0
```

```sh
dart pub get
```

The official `capnp` compiler must also be installed and on `PATH` —
`capnpc_dart_builder` shells out to it to parse your schemas.

## Build and read a message

`build_runner` only looks under `lib/`, so put your schema at, say,
`lib/schema/hello.capnp`, then run `dart run build_runner build` to generate
`lib/schema/hello.capnp.dart`:

```dart
import 'package:capnproto_dart/capnproto_dart.dart';
import 'schema/hello.capnp.dart';

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

That's the core workflow: build a message, serialize it to bytes, and read
it back. The generated factory is always named `<StructName>Factory` (lower
camelCase), one per struct in your schema.

## Also available

You likely won't need these on day one, but they're here when you do:

- **Packed encoding** (`serializePacked`/`deserializePacked`) — a smaller
  wire format for the same messages.
- **Message streams** (`MessageStream`) — read or write several messages
  back-to-back over a socket or file.
- **Text format** (`encodeText`/`decodeText`) — human-readable output, handy
  for debugging or test fixtures.
- **Dynamic access** — inspect a message without knowing its schema type at
  compile time.

See the [serialization guide](https://angrymane.github.io/capnproto-dart/howto/serialization)
and [API documentation](https://pub.dev/documentation/capnproto_dart/latest/)
for details on all of the above.
