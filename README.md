# capnproto-dart

A pure Dart implementation of [Cap'n Proto](https://capnproto.org) serialization and RPC, with no FFI dependency.

[![CI](https://github.com/AngryMane/capnproto-dart/actions/workflows/compat.yml/badge.svg)](https://github.com/AngryMane/capnproto-dart/actions/workflows/compat.yml)

## Why

The only existing way to use Cap'n Proto from Flutter is to call C++ or Rust libraries via FFI.  
This approach introduces complex build configurations, hard-to-debug FFI boundaries.  

This repository provides a pure Dart implementation that integrates like any other Dart package.  

## Quick Start

Most apps built on this library talk to another process over RPC — that's the path below.  

### 1. Install

Add the runtime and the code-generation builder to `pubspec.yaml`:

```yaml
dependencies:
  capnproto_dart_rpc: ^0.1.0

dev_dependencies:
  build_runner: ^2.4.13
  capnpc_dart_builder: ^0.1.0
```

```sh
dart pub get
```

The official `capnp` compiler must also be installed and on `PATH` — `capnpc_dart_builder` shells out to it to parse your schemas.  

### 2. Write a schema

`build_runner` only looks under `lib/`, so put schema files there:

```capnp
# lib/schema/hello.capnp
@0xdeadbeefdeadbeef;

interface Greeter {
  greet @0 (name :Text) -> (reply :Text);
}
```

### 3. Generate Dart code

```sh
dart run build_runner build
```

`capnpc_dart_builder` finds every `.capnp` file in your package, runs it through `capnp`, and writes `lib/schema/hello.capnp.dart` next to it.  
Re-run this command after editing a schema; add `--delete-conflicting-outputs` if build_runner complains about stale output.

### 4. Implement a server

```dart
import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'schema/hello.capnp.dart';

class MyGreeter extends GreeterServer {
  @override
  Future<DispatchResult> greet(
    GreeterGreetParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    return buildGreetResults((out) => out.reply = 'Hello, ${params.name}!');
  }
}

Future<void> main() async {
  await RpcSystem.serve(Uri.parse('tcp://0.0.0.0:12345'), MyGreeter());
}
```

### 5. Call it from a client

```dart
import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'schema/hello.capnp.dart';

Future<void> main() async {
  final conn = await RpcSystem.connect(Uri.parse('tcp://127.0.0.1:12345'));
  final greeter = conn.bootstrap(GreeterClientFactory());

  final result = await greeter.greet((b) => b.name = 'World');
  print(result.reply); // Hello, World!

  await greeter.dispose();
  await conn.close();
}
```

## RPC Support Status

This library implements **Cap'n Proto RPC Level 1** for two-party connections:

| Feature | Status |
|---|---|
| Object-capability references | Supported |
| Promise pipelining | Supported |
| Bidirectional RPC (callbacks) | Supported |
| Tail calls (`Capability.tryTailCall`) | Supported |
| Receiving `Resolve` / `Disembargo` from peer | Supported |
| Sending `Resolve` / `Disembargo` from Dart vat | Supported |
| Three-party handoff (Level 3) | **Not in scope** |
| Persistent capabilities (Level 2) | **Not in scope** |
| Reference equality / Join (Level 4) | **Not in scope** |

Level 2 (persistent capabilities), Level 3 (three-party handoff), and Level 4 (Join) are not implemented.  
Weak capability references, batch Release, `releaseParamCaps`, and `noFinishNeeded` (all Level 1 optimizations, not correctness requirements) are also not implemented.  
Applications with long-lived connections and high capability churn should release capabilities promptly and should validate their workload against the lifecycle/stress tests in this repository.

The RPC layer is tested for interoperability with Rust servers/clients using the [`capnp`](https://crates.io/crates/capnp) crate (versions 0.23–0.26).

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
- Dart SDK 3.7.2 (the minimum supported version; CI also tests latest stable)
- Rust via rustup

```sh
# Open in VS Code → "Reopen in Container"
# or use the Dev Containers CLI:
devcontainer up --workspace-folder .
```

### Running tests

```sh
# Generator tests
dart test dev_packages/capnpc-dart/

# Runtime tests
dart test packages/capnproto_dart/
dart test packages/capnproto_dart_rpc/

# Everything above, plus the cross-language interop suites in test/interop/
# (requires the `capnp` CLI and a Rust toolchain — see ci/run-tests.sh)
ci/run-tests.sh
```

### CI

The GitHub Actions workflow (`.github/workflows/compat.yml`) runs analysis and tests with various Dart SDK.  
It also runs the full interoperability suite against capnp crate versions 0.23 through 0.26 on every push to `main`.  

## License

MIT — see [`LICENSE`](LICENSE).
