# capnpc_dart

Turns your `.capnp` schema files into Dart code.  

This package is a compiler plugin invoked by the official `capnp` compiler.  
Most apps should use [`capnpc_dart_builder`](https://pub.dev/packages/capnpc_dart_builder) instead of driving this package by hand.  
Read on if you want to invoke `capnp compile` yourself instead, e.g. from a script or CI step outside build_runner.  

## How the pieces fit together

- `capnpc_dart` (this package)  
  generates Dart source from `.capnp` schemas.  
- The generated code  
  depends on [`capnproto_dart`](https://pub.dev/packages/capnproto_dart).  

## Requirements

- Dart SDK 3.7.2 or newer
- The official `capnp` command-line compiler on `PATH`

Check the compiler installation with:

```sh
capnp --version
```

`capnpc-dart` itself is invoked by `capnp`, so if `capnp` isn't installed you'll
see a shell error (e.g. `capnp: command not found`) before `capnpc-dart` ever
runs. The one exception is `--check` mode (below), which shells out to `capnp`
itself and fails with a `CapnpLaunchException` if `capnp` can't be launched
(not installed, not on `PATH`, or a permissions issue):

```
capnpc-dart: check mode error: capnp could not be launched: No such file or
directory. This usually means `capnp` is not installed or not on PATH —
install it yourself, see https://capnproto.org/install.html — but could also
be a permissions or other OS-level launch failure. Underlying error:
ProcessException: No such file or directory
  Command: capnp compile ...
```

## Install

```sh
dart pub global activate capnpc_dart
```

If Dart's global executable directory is not on `PATH`, follow the instruction printed by `dart pub global activate` before running `capnp compile`.  

## Generate Dart code

```sh
capnp compile -o dart:lib/src/generated schema/hello.capnp
```

This writes `lib/src/generated/schema/hello.capnp.dart`.  
`capnp` finds the generator automatically once it's globally activated as `capnpc-dart` — you don't invoke it yourself.  

Compile every schema file whose types you use directly, including imported ones:  

```sh
capnp compile -o dart:lib/src/generated \
  schema/hello.capnp schema/common.capnp
```

Then add the runtime the generated code needs:

```sh
dart pub add capnproto_dart
```

Add `capnproto_dart_rpc` too if your schema declares any interfaces.

## Keep versions in sync

Use the same release line for `capnpc_dart`, `capnproto_dart`, and
`capnproto_dart_rpc`. Generated code is compiled against runtime APIs and
isn't guaranteed to work with a mismatched version.

## Also available

Checking whether a schema change is backward-compatible before you ship it:

```sh
capnp compile -o- schema/new.capnp \
  | capnpc-dart --check=schema/old.capnp
```

Exit status is `0` for compatible changes, `1` for detected
incompatibilities, and `2` for invocation or processing errors.

See the [schema and code-generation guide](https://angrymane.github.io/capnproto-dart/howto/schema-and-codegen)
for imports, constants, generated names, and current limitations.
