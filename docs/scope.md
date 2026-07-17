# Scope

This repository contains three components in a single codebase. They may be separated into individual repositories in the future if needed.

---

## Component 1: CLI Tool (build-time)

Used by developers to generate Dart code from `.capnp` schema files.

| ID | Feature | Description |
|---|---|---|
| F-03 | `.capnp` schema parser | Delegated to the official `capnp` compiler via its plugin mechanism. Not implemented in this repository. |
| F-04 | Dart code generator (`capnpc-dart`) | Receives `CodeGeneratorRequest` from the official compiler via stdin and generates Dart source files. Also handles F-08 via an option flag. Implementation language is not restricted to Dart. |
| F-08 | Schema compatibility check | Built into `capnpc-dart` as an option mode, invoked as `capnp compile -o- <new.capnp> \| capnpc-dart --check=<old.capnp>` (see `tools/capnpc-dart/doc/external-spec.md`). No separate binary. |

---

## Component 2: Serialization Runtime (`capnproto_dart`, application-level)

A pure Dart library embedded in Flutter/Dart applications. The generated code (Component 1) depends on this library.

| ID | Feature | Description |
|---|---|---|
| F-01 | Cap'n Proto binary encoding | Serialize Dart objects into Cap'n Proto binary format |
| F-02 | Cap'n Proto binary decoding | Deserialize Cap'n Proto binary data into Dart objects |
| F-06 | Packed encoding | Reduce data size by compressing zero bytes |
| F-07 | Streaming support | Send and receive large messages in segments |

---

## Component 3: RPC Runtime (`capnproto_dart_rpc`, application-level, optional)

A pure Dart library depended on by applications that need Cap'n Proto RPC. Depends on Component 2 (`capnproto_dart`) for message encoding; not required for applications that only serialize/deserialize.

| ID | Feature | Description |
|---|---|---|
| F-05 | Cap'n Proto RPC | Remote procedure calls between client and server over a network |

---

## Out of Scope

- Bindings to existing C++ or Rust Cap'n Proto libraries via FFI
- Interoperability testing with non-Dart Cap'n Proto implementations (may be added later)
- Schema IDE integration (e.g., language server, syntax highlighting)
