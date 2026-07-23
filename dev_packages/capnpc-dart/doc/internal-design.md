# Internal Design: CLI Tool (`capnpc-dart`)

> **Status: stub.** Unlike the Serialization Runtime and RPC Runtime, this component's
> internal architecture (layer structure, data flow, key design patterns) has not been
> written up yet. Rather than invent a design narrative that hasn't been verified against
> the current implementation, this stub only inventories the source layout as a starting
> point. A full internal-design pass (layer diagram, `CodeGeneratorRequest` → AST → Dart
> source data flow, compat-check algorithm) is tracked as follow-up work.

## Module Layout

```
dev_packages/capnpc-dart/
├── bin/
│   └── capnpc_dart.dart      # Entry point: reads CodeGeneratorRequest from stdin
└── lib/
    ├── capnpc_dart.dart      # Public barrel export
    └── src/
        ├── codegen.dart               # Top-level orchestration: request -> generated files
        ├── schema/
        │   ├── schema_reader.dart     # Parses CodeGeneratorRequest into an internal model
        │   └── schema_model.dart      # Internal AST-like representation of the schema
        ├── generator/
        │   └── dart_generator.dart    # Internal model -> generated Dart source
        └── compat/
            ├── compat_checker.dart    # `check=<old.capnp>` compatibility diffing
            └── schema_capture.dart    # Captures a schema snapshot for compat comparison
```
