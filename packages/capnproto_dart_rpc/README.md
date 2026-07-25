# capnproto_dart_rpc

RPC runtime for Cap'n Proto in Dart — connect to a server, call its methods,
and get typed results back. Use this package when your app talks to another
process over the network, rather than just reading/writing Cap'n Proto
messages locally.

## How the pieces fit together

- [`capnpc_dart`](https://pub.dev/packages/capnpc_dart) generates typed
  client and server classes from your `.capnp` schema.
- `capnproto_dart_rpc` (this package) is the runtime those generated classes
  use to connect, call, and dispatch. It already includes
  [`capnproto_dart`](https://pub.dev/packages/capnproto_dart) (message
  serialization), so you don't need to add that separately.

## Install and generate stubs

Add this package and the code-generation builder to `pubspec.yaml`:

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

`build_runner` only looks under `lib/`, so put your schema there, e.g.
`lib/schema/greeter.capnp`, then generate stubs:

```sh
dart run build_runner build
```

This writes `lib/schema/greeter.capnp.dart`. The official `capnp` compiler
must also be installed and on `PATH` — `capnpc_dart_builder` shells out to it
to parse your schemas.

## Connect and call

```dart
import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'schema/greeter.capnp.dart';

Future<void> main() async {
  final connection =
      await RpcSystem.connect(Uri.parse('tcp://127.0.0.1:12345'));
  final greeter = connection.bootstrap(GreeterClientFactory());

  try {
    final result = await greeter.greet((params) => params.name = 'World');
    print(result.reply);
  } finally {
    await greeter.dispose();
    await connection.close();
  }
}
```

That's the core client workflow: connect, get the remote object
(`bootstrap`), call its methods like normal Dart methods, and clean up when
done. Swap `tcp://` for `ws://` or `wss://` to connect over WebSocket
instead.

Always call `dispose()` on capabilities you're finished with, and `close()`
on the connection — each remote reference stays alive on the server until
you release it.

## Serving requests

If your app also needs to accept incoming calls — acting as a server, or
answering a callback passed to you by one — implement the generated
`<Name>Server` base class:

```dart
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
  final server = await RpcSystem.serve(
    Uri.parse('tcp://0.0.0.0:12345'),
    MyGreeter(),
  );
  // Later: await server.close();
}
```

`RpcSystem.serve` also accepts `ws://` and `wss://` addresses.

## Learn more

See the [RPC guide](https://angrymane.github.io/capnproto-dart/howto/rpc) and
[API documentation](https://pub.dev/documentation/capnproto_dart_rpc/latest/)
for promise pipelining, streaming calls, error handling, and the full
protocol support matrix.
