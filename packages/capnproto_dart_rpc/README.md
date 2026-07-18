# capnproto_dart_rpc

Pure Dart Cap'n Proto RPC runtime for two-party connections over TCP and
WebSocket. It implements a practical Level 1 subset with callbacks, promise
pipelining, tail calls, and Resolve/Disembargo in both directions.

The package re-exports `capnproto_dart`, so applications using generated RPC
code normally need only this import.

## Install and generate stubs

```sh
dart pub add capnproto_dart_rpc
dart pub global activate capnpc_dart
capnp compile -o dart:lib/src/generated schema/greeter.capnp
```

The official `capnp` CLI must be installed separately.

## Connect and call

```dart
import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'src/generated/greeter.capnp.dart';

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

Use `ws://host:port/path` or `wss://host:port/path` instead of `tcp://` for
WebSocket transport.

## Serve a bootstrap capability

Each schema interface generates a `<Name>Server` base class:

```dart
class MyGreeter extends GreeterServer {
  @override
  Future<DispatchResult> greet(
    GreeterGreetParamsReader params,
    List<Capability> paramsCapabilities,
  ) async {
    final message = MessageBuilder();
    final result = message.initRoot(greeterGreetResultsFactory);
    result.reply = 'Hello, ${params.name}!';
    return DispatchResult(bytes: message.serialize());
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

`RpcSystem.serve` also accepts `ws://` and `wss://` addresses. A `wss://`
server requires a Dart `SecurityContext`. WebSocket request paths are enforced.

## Capability lifetime

Capabilities are live remote references. Dispose clients and capabilities when
they are no longer needed so the peer can release its export:

```dart
final session = (await greeter.newSession((p) => p.name = 'Ada')).session;
try {
  await session.greet((_) {});
} finally {
  await session.dispose();
}
```

Closing an `RpcConnection` releases all state owned by that connection. A
capability must not be used after it or its connection has been disposed.

## Protocol scope

Supported Level 1 functionality includes two-party bootstrap, calls and
returns, capability parameters/results, callbacks, promise pipelining,
sender promises, tail calls, Release/Finish, and Resolve/Disembargo flows.

This is not a complete Level 1 or Level 2 implementation. In particular,
three-party handoff and persistent capabilities are unsupported. Unsupported
capability descriptors fail the connection explicitly with an
`unimplemented` RPC error; they are never silently treated as null.

Long-lived services with high capability churn should dispose references
promptly and test their workload under realistic connection counts. Servers
can set `maxConnections`; streaming methods use bounded flow control.

See the [RPC guide](https://angrymane.github.io/capnproto-dart/howto/rpc),
[support matrix](https://github.com/AngryMane/capnproto-dart#rpc-support-status),
and [API documentation](https://pub.dev/documentation/capnproto_dart_rpc/latest/)
for more detail.
