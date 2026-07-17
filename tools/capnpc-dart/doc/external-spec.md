# External Spec: CLI Tool (`capnpc-dart`)

The CLI Tool is implemented as a plugin for the official `capnp` compiler. Schema parsing is delegated to the official compiler; this component handles only code generation and compatibility checking. The implementation language is not restricted to Dart.

## `capnpc-dart` — Code Generator Plugin

Invoked by the `capnp` compiler via its plugin mechanism. Users do not call this binary directly.

```
# User-facing invocation (capnp compiler delegates to capnpc-dart)
capnp compile -o dart <schema.capnp...>
```

**Input**: `CodeGeneratorRequest` message in Cap'n Proto binary format, received via **stdin**
**Output**: Generated `.dart` source files written to disk
**Exit code**: `0` on success, non-zero on error

### Compatibility check mode

```
capnp compile -o dart:check=<old.capnp> <new.capnp>
```

**Input**: `CodeGeneratorRequest` for the new schema via **stdin**; old schema path provided as the `check` option
**Output**: List of incompatible changes printed to stdout
**Exit code**: `0` if compatible, `1` if incompatible changes are detected, `2` on error

## Dependency

`capnpc-dart` requires the official `capnp` compiler to be installed on the developer's machine. It is used at build time only and is never shipped with the Flutter/Dart application.

## Generated Code Interface

`capnpc-dart` generates one `.dart` file per `.capnp` file. The generated code provides
typed accessors built on top of the [`capnproto_dart` Serialization Runtime](pathname:///capnproto_dart/external-spec) base classes (`StructReader`, `StructBuilder`, `StructFactory`, ...).

### Example: Schema

```capnp
struct Person {
  name @0 :Text;
  age  @1 :UInt32;
  address @2 :Address;
}

struct Address {
  city @0 :Text;
}
```

### Example: Generated Dart Code

```dart
// Generated — do not edit by hand.

import 'package:capnproto_dart/capnproto_dart.dart';

// ignore_for_file: annotate_overrides

final class PersonReader extends StructReader {
  String      get name    => ...;
  int         get age     => ...;
  AddressReader get address => ...;
  bool        hasAddress()  => ...;
}

final class PersonBuilder extends StructBuilder {
  String      get name      => ...;
  set name(String value)    => ...;
  int         get age       => ...;
  set age(int value)        => ...;
  AddressReader get address => ...;
  AddressBuilder initAddress() => ...;
  bool        hasAddress()     => ...;

  @override
  PersonReader asReader() => ...;
}

final personFactory = _PersonFactory();
```
