# Getting Started

**Audience**: a Flutter/Dart application developer who wants to use Cap'n Proto for
serialization and/or RPC without an FFI dependency on the C++ reference implementation.

## Overall Flow

```
Define .capnp schema → Generate Dart code → Integrate into app → Serialize / Deserialize / RPC
```

## Prerequisites

- Dart SDK (see `.devcontainer/Dockerfile` for the pinned version used in CI)
- The official `capnp` compiler (`capnpc-dart` is a plugin for it, not a standalone
  compiler — see [`schema-and-codegen.md`](schema-and-codegen.md))
- Rust + `cargo`, only if you plan to run the cross-language interop suites under
  `test/interop/` or the `sample/greeter` server

A ready-to-use dev container (`.devcontainer/`) already has all of the above; see the
repository root [`README.md`](https://github.com/AngryMane/capnproto-dart/blob/main/README.md#development) for how to open it.

## 1. Install the code generator

```sh
dart pub global activate --source path tools/capnpc-dart
```

## 2. Write a schema

```capnp
# hello.capnp
@0xdeadbeefdeadbeef;

struct Greeting {
  name @0 :Text;
  reply @1 :Text;
}
```

## 3. Generate Dart code

```sh
capnp compile -o dart:lib/src/generated hello.capnp
```

This produces `lib/src/generated/hello.capnp.dart` with typed reader and builder classes.
See [`schema-and-codegen.md`](schema-and-codegen.md) for schema-evolution / compatibility
checking.

## 4. Use in Dart

```dart
import 'package:capnproto_dart/capnproto_dart.dart';
import 'src/generated/hello.capnp.dart';

void main() {
  // Build a message
  final builder = MessageBuilder();
  final greeting = builder.initRoot(greetingFactory);
  greeting.name = 'World';

  // Serialize
  final bytes = builder.serialize();

  // Deserialize
  final reader = MessageReader.deserialize(bytes);
  final g = reader.getRoot(greetingFactory);
  print(g.name); // World
}
```

See [`serialization.md`](serialization.md) for packed encoding, streaming, and dynamic
(schema-less) access.

## 5. RPC (optional)

```dart
import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'src/generated/greeter.capnp.dart';

Future<void> main() async {
  final conn = await RpcSystem.connect(Uri.parse('tcp://127.0.0.1:12345'));
  final greeter = conn.bootstrap(GreeterClientFactory());

  final result = await greeter.greet((b) => b.name = 'World');
  print(result.reply);

  await conn.close();
}
```

See [`rpc.md`](rpc.md) for bootstrap, capabilities, promise pipelining, and streaming
calls, and [`samples-and-testing.md`](samples-and-testing.md) to run a working
client/server pair end to end.
