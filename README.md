# capnproto-dart

A pure Dart implementation of [Cap'n Proto](https://capnproto.org) serialization and RPC, with no FFI dependency.

[![CI](https://github.com/AngryMane/capnproto-dart/actions/workflows/compat.yml/badge.svg)](https://github.com/AngryMane/capnproto-dart/actions/workflows/compat.yml)

## Why

The only existing way to use Cap'n Proto from Flutter is to call C++ or Rust libraries via FFI. This approach introduces complex build configurations, hard-to-debug FFI boundaries, and threading mismatches. This repository provides a pure Dart implementation that integrates like any other Dart package.

## Repository Layout

```
capnproto-dart/
├── tools/
│   └── capnpc-dart/          # Code generator plugin (dart pub global activate)
├── packages/
│   ├── capnproto_dart/       # Serialization + streaming runtime
│   └── capnproto_dart_rpc/   # RPC runtime (Level 1 subset)
├── sample/
│   └── greeter/              # Simple Dart↔Rust greeter (RPC basics)
├── test/
│   └── interop/              # Cross-language correctness suites (Dart↔Rust), run by ci/run-tests.sh
│       ├── complex/               # 29-section RPC interop suite, both directions
│       ├── schema-evolution/      # Runtime forward/backward-compat cross-check
│       └── wire-format-golden/    # Wire-format cross-check against the official capnp CLI
└── docs/                     # Design documents
```

## Quick Start

### 1. Install the code generator

```sh
dart pub global activate --source path tools/capnpc-dart
```

### 2. Write a schema

```capnp
# hello.capnp
@0xdeadbeefdeadbeef;

struct Greeting {
  name @0 :Text;
  reply @1 :Text;
}
```

### 3. Generate Dart code

```sh
capnp compile -o dart:lib/src/generated hello.capnp
```

This produces `lib/src/generated/hello.capnp.dart` with typed reader and builder classes.

### 4. Use in Dart

```dart
import 'package:capnproto_dart/capnproto_dart.dart';
import 'src/generated/hello.capnp.dart';

void main() {
  // Build a message
  final builder = MessageBuilder();
  final greeting = builder.initRoot(GreetingBuilder.factory);
  greeting.name = 'World';

  // Serialize
  final bytes = builder.toFlatBytes();

  // Deserialize
  final reader = MessageReader.fromBytes(bytes);
  final g = reader.getRoot(GreetingReader.factory);
  print(g.name); // World
}
```

### 5. RPC (optional)

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

## RPC Support Status

This library implements a **Cap'n Proto RPC Level 1 subset** for two-party connections:

| Feature | Status |
|---|---|
| Object-capability references | Supported |
| Promise pipelining | Supported |
| Bidirectional RPC (callbacks) | Supported |
| Receiving `Resolve` / `Disembargo` from peer | Supported |
| Sending `Resolve` / `Disembargo` from Dart vat | **Not implemented** |
| Three-party handoff (Level 1 full) | **Not in scope** |
| Persistent capabilities (Level 2+) | **Not in scope** |

The RPC layer is tested for interoperability with Rust servers/clients using the [`capnp`](https://crates.io/crates/capnp) crate (versions 0.20–0.26).

## Samples

### `sample/greeter` — Simple greeter

A minimal Dart client + Rust server demonstrating basic RPC calls and session capabilities.

```sh
# Terminal 1: start the Rust server
cargo run --manifest-path sample/greeter/server/Cargo.toml

# Terminal 2: run the Dart client
dart run sample/greeter/client/bin/main.dart
```

## Cross-Language Interop Tests

`test/interop/` holds correctness suites, not usage samples — see [`ci/run-tests.sh`](ci/run-tests.sh) for the full, automated run. Each suite is runnable by hand too:

### `test/interop/complex` — RPC interop suite

A 29-section test covering encoding, all field types, pipelining, bidirectional callbacks, and Level 1 subset flows, driven in both directions (Dart client ↔ Rust server, and Rust client ↔ Dart server).

```sh
# Dart client against the Rust server
cargo run --manifest-path test/interop/complex/server/Cargo.toml &
dart run test/interop/complex/client/bin/main.dart

# Or the Rust client against the Dart server
dart run test/interop/complex/dart-server/bin/main.dart &
cargo run --manifest-path test/interop/complex/rust-client/Cargo.toml
```

### `test/interop/schema-evolution` — runtime forward/backward compatibility

Proves at runtime, across both languages, that a message written against an old schema version is readable by the other language's newer schema (and vice versa) — see [`ci/run-tests.sh`](ci/run-tests.sh) for the four write/read combinations it drives.

### `test/interop/wire-format-golden` — official `capnp` CLI as oracle

Independent of RPC: checks that this library's serialized bytes are byte-for-byte interchangeable with the official C++ reference implementation, using the `capnp decode`/`capnp encode` CLI as ground truth.

## Development

A ready-to-use dev container is provided (`.devcontainer/`). It sets up Ubuntu 24.04 with:
- Cap'n Proto CLI built from source (v1.0.1)
- Dart SDK 3.7.2
- Rust via rustup

```sh
# Open in VS Code → "Reopen in Container"
# or use the Dev Containers CLI:
devcontainer up --workspace-folder .
```

### Running tests

```sh
# Generator tests
dart test tools/capnpc-dart/

# Runtime tests
dart test packages/capnproto_dart/
dart test packages/capnproto_dart_rpc/

# Everything above, plus the cross-language interop suites in test/interop/
# (requires the `capnp` CLI and a Rust toolchain — see ci/run-tests.sh)
ci/run-tests.sh
```

### CI

The GitHub Actions workflow (`.github/workflows/compat.yml`) tests against capnp crate versions 0.20 through 0.26 on every push to `main`.

## Documentation

Design documents are in [`docs/`](docs/):

| File | Contents |
|---|---|
| [`purpose.md`](docs/purpose.md) | Problem statement and motivation |
| [`scope.md`](docs/scope.md) | Feature scope and out-of-scope items |
| [`global-design.md`](docs/global-design.md) | Overall architecture |
| [`boundary-design.md`](docs/boundary-design.md) | Public API surface |
| [`internal-design.md`](docs/internal-design.md) | Internal design and data structures |
| [`usecase.md`](docs/usecase.md) | Use-case walkthrough |
| [`constraint.md`](docs/constraint.md) | Design constraints |
