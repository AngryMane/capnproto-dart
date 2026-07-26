# capnpc_dart_builder

`build_runner` integration for [`capnpc_dart`](https://pub.dev/packages/capnpc_dart).

## How the pieces fit together

- `capnpc_dart_builder` (this package)  
  wraps [`capnpc_dart`](https://pub.dev/packages/capnpc_dart)'s generator in a `build_runner` builder.  
- The generated code 
  depends on [`capnproto_dart`](https://pub.dev/packages/capnproto_dart)

## Install

```yaml
dev_dependencies:
  build_runner: ^2.4.13
  capnpc_dart_builder: ^0.1.0
```

```sh
dart pub get
```

The official `capnp` compiler must also be installed and on `PATH`. it does not parse `.capnp` syntax itself.  

If `capnp` can't be launched (not installed, not on `PATH`, or a permissions
issue), the build fails with a `CapnpLaunchException`:

```
capnp compile failed: could not launch the `capnp` command-line compiler
(No such file or directory). This usually means `capnp` is not installed or
not on PATH — install it yourself, see https://capnproto.org/install.html —
but could also be a permissions or other OS-level launch failure. Underlying
error: ProcessException: No such file or directory
  Command: capnp compile ...
```

## Generate Dart code

`build_runner` only looks under `lib/`, so put schema files there:

```capnp
# lib/schema/hello.capnp
@0xdeadbeefdeadbeef;

struct Greeting {
  name @0 :Text;
  reply @1 :Text;
}
```

```sh
dart run build_runner build
```

This writes `lib/schema/hello.capnp.dart` next to your schema.  
Re-run after editing a schema; add `--delete-conflicting-outputs` if build_runner complains about stale output.  

## Custom import paths

Schemas that `import` a file outside their own package (capnp's `-I`-rooted imports) need an extra search root,  
since `build_runner` can only see files inside the package being built. Add one via the builder's `import_paths` option in your own `build.yaml`:  

```yaml
targets:
  $default:
    builders:
      capnpc_dart_builder|capnp:
        options:
          import_paths: ["../shared_schemas"]
```

See the [schema and code-generation guide](https://angrymane.github.io/capnproto-dart/howto/schema-and-codegen)
for imports, constants, generated names, and current limitations.
