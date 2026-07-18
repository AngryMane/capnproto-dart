# External Spec: RPC Runtime (`capnproto_dart_rpc`)

A pure Dart library with no FFI dependencies. Depends on the
[Serialization Runtime (`capnproto_dart`)](pathname:///capnproto_dart/external-spec) for
message encoding; only needed by applications that use RPC.

Implements a **Cap'n Proto RPC Level 1 subset**: object-capability references and promise pipelining
in two-party connections. The following Level 1 features are **not** implemented:
- `Resolve` and `Disembargo` messages sent by the Dart vat (only received/processed when sent by a peer)
- Three-party handoff (required for full Level 1 compliance)

Level 2 and above (persistent capabilities) are out of scope.

## Core RPC types

```dart
/// Base class for all Cap'n Proto capabilities (remote object references).
/// A capability both designates an object and confers permission to call it.
abstract class Capability {
  Future<void> dispose();
}

/// Manages an RPC connection to a remote peer.
abstract class RpcConnection {
  /// Returns the bootstrap capability offered by the remote peer.
  T bootstrap<T extends Capability>(CapabilityFactory<T> factory);

  /// Closes the connection and releases all associated capabilities.
  Future<void> close();
}

/// Factory for wrapping a raw RPC connection as a typed capability.
abstract class CapabilityFactory<T extends Capability> {
  T fromConnection(RpcConnection connection);
}

/// Entry point for establishing and serving RPC connections.
class RpcSystem {
  /// Connects to a remote Cap'n Proto RPC server.
  ///
  /// [onDisposeError] observes a capability's `dispose()` throwing during
  /// internal cleanup — such a failure never blocks or fails the
  /// surrounding operation, so this is the only way to see it.
  static Future<RpcConnection> connect(Uri address,
      {void Function(Object error, StackTrace stackTrace)? onDisposeError});

  /// Starts a server and serves the given bootstrap capability to incoming clients.
  static Future<RpcServer> serve(Uri address, Capability bootstrap,
      {void Function(Object error, StackTrace stackTrace)? onDisposeError});
}

/// Represents a running Cap'n Proto RPC server.
abstract class RpcServer {
  Future<void> close();
}
```

> **Note:** this signature block predates the current implementation and has not been
> re-verified against it (e.g. the real `CapabilityFactory` exposes `fromCapability`, not
> `fromConnection`). It was carried over as-is during a docs restructuring pass — treat it
> as a rough sketch of the public shape, not a byte-for-byte accurate reference, until a
> follow-up accuracy pass reconciles it with `lib/src/rpc/` and `lib/src/capability/`.

## Promise Pipelining

Dart's `Future<T>` naturally supports promise pipelining. Generated client stubs return
`Future<T>` where `T` is itself a capability, enabling callers to chain calls without
waiting for intermediate results to resolve:

```dart
// Without pipelining: 2 round-trips
final fooResult = await client.getFoo();
final barResult = await fooResult.getBar();

// With pipelining: 1 round-trip (calls are sent immediately)
final barResult = await client.getFoo().then((foo) => foo.getBar());
```

The runtime sends both calls to the server in a single round-trip when the intermediate
result is a capability.

## Tail Calls

A server-side capability can answer a call by forwarding it to another capability's
method, instead of running its own logic — this is the Cap'n Proto RPC "tail call"
mechanism (`Call.sendResultsTo=yourself` / `Return.takeFromOtherQuestion`, both Level 1).
Override `Capability.tryTailCall` to opt in:

```dart
class MyCap extends Capability {
  @override
  TailCall? tryTailCall(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (methodId != forwardMethodId) return null;
    return TailCall(someOtherCap, targetInterfaceId, targetMethodId, targetParams);
  }
}
```

Returning non-null skips `dispatchWithContext` entirely for that call: the whole result
becomes whatever `TailCall.target`'s method returns. When `target` is a capability
imported from the same peer connection that sent the original call, the runtime applies
the real wire optimization — the peer resolves the answer itself, without an extra round
trip through this vat. For any other target, the call still completes correctly, just as
a normal (non-optimized) proxy.

**Known limitations:**
- Pipelining a further call onto an answer that was itself resolved via
  `takeFromOtherQuestion` is not supported — the pipelined call fails with a clear
  `RpcException` rather than hanging or returning a wrong answer.
- A call already flagged `sendResultsTo=yourself` (i.e. this vat is itself the target of
  a peer's tail call) never consults `tryTailCall` again — chained/nested tail calls
  aren't supported; the call just dispatches normally.

## Error Handling

RPC errors extend `CapnpException` (defined in the Serialization Runtime, `capnproto_dart`).

```dart
/// Thrown when an RPC call fails (e.g., connection lost, remote exception).
class RpcException extends CapnpException {}
```
