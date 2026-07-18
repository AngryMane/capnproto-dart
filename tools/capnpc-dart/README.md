# capnpc_dart

Dart code-generator plugin for the official Cap'n Proto compiler. It generates
typed readers, builders, schema metadata, and RPC stubs from `.capnp` files.

Generated code depends on the matching `capnproto_dart` runtime version.

## Requirements

- Dart SDK 3.7.2 or newer
- The official `capnp` command-line compiler on `PATH`

Check the compiler installation with:

```sh
capnp --version
```

## Install

```sh
dart pub global activate capnpc_dart
```

If Dart's global executable directory is not on `PATH`, follow the instruction
printed by `dart pub global activate` before running `capnp compile`.

## Generate Dart code

For `schema/hello.capnp`, generate code under `lib/src/generated` with:

```sh
capnp compile -o dart:lib/src/generated schema/hello.capnp
```

The `capnp` compiler finds the globally activated executable as
`capnpc-dart`. One file is generated for each input schema, preserving its
relative path and adding `.dart`; for example:

```text
lib/src/generated/schema/hello.capnp.dart
```

Compile imported schemas explicitly when their Dart output is also required:

```sh
capnp compile -o dart:lib/src/generated \
  schema/hello.capnp schema/common.capnp
```

Add the runtime used by the generated file to the application:

```sh
dart pub add capnproto_dart
```

Schemas containing interfaces also require `capnproto_dart_rpc`.

## Compatibility checking

The generator can compare a new schema request with an older schema. Because
`capnp -o` does not forward arbitrary plugin options, pipe the request directly:

```sh
capnp compile -o- schema/new.capnp \
  | capnpc-dart --check=schema/old.capnp
```

Exit status is `0` for compatible changes, `1` for detected incompatibilities,
and `2` for invocation or processing errors.

## Version compatibility

Use the same release line for `capnpc_dart`, `capnproto_dart`, and
`capnproto_dart_rpc`. Generated source is compiled against runtime APIs and is
not guaranteed to work with an older runtime package.

See the [schema and code-generation guide](https://angrymane.github.io/capnproto-dart/howto/schema-and-codegen)
for imports, constants, generated names, and current limitations.
