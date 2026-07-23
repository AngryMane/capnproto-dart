# `capnproto_dart_rpc` Public Symbol Reference

This document catalogs the RPC-specific symbols exported by the public library `package:capnproto_dart_rpc/capnproto_dart_rpc.dart`.  
In the Consumers column,  

* "Generated code" refers to interface clients, server bases, and helpers produced by `capnpc_dart`;  
* "App" refers to applications that establish connections, obtain capabilities, and make typed calls;  
* "Server implementation" refers to application code implementing generated server bases;  
* "RPC runtime" refers to this package's connection and wire-protocol implementation;  
* "Both" means client-side App code and Server implementation code together. A symbol primarily used by generated code or the RPC runtime keeps that narrower label even when advanced applications can use it directly.  

## Connections and Servers

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `RpcSystem` | Class | Establishes clients and servers over TCP, WebSocket, or secure WebSocket transports. | App | Connecting to an RPC endpoint or serving a bootstrap capability at a URI. |
| `RpcConnection` | Abstract class | Represents an active peer connection and provides typed bootstrap lookup and closure. | App | Obtaining the peer's bootstrap capability and releasing the connection. |
| `RpcServer` | Abstract class | Represents a listening RPC server, exposing its bound port and shutdown operation. | App | Managing a server returned by `RpcSystem.serve`, especially when binding to port zero. |

## Capabilities

### Base Types and Factories

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `Capability` | Abstract class | Base abstraction for a callable Cap'n Proto object reference, including ordinary, streaming, pipelined, builder-based, and cancellable dispatch. | Generated code | Base for generated server implementations and the untyped target wrapped by generated client stubs. |
| `CapabilityFactory<T>` | Abstract class | Converts an untyped `Capability` into a generated typed capability client. | Generated code | Supplying a factory to bootstrap lookup, interface-field decoding, and generic capability decoding. |
| `CapabilityAnyPointerCodec<T>` | Final class | Encodes and decodes capabilities passed through generic `AnyPointer` values, using a capability table and an optional typed factory. | Generated code | Implementing generic RPC methods whose type parameter is an interface. |
| `DeferredCapability` | Class | Defers calls until a `Future<Capability>` resolves and exposes that resolution for sender-promise handling. | Server implementation / RPC runtime | Returning a capability that will resolve asynchronously, and providing the local pipelining fallback. |

### Calls and Dispatch

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `RpcPayload` | Final class | Wraps call parameters or results as serialized bytes, an in-place envelope view, or an unserialized builder root. | Generated code | Reading typed parameters/results without unnecessary serialization and copying. |
| `DispatchResult` | Class | Holds an RPC result payload and its capability table; also provides the shared empty result. | Generated code | Returning results from generated server dispatch and receiving results in generated clients. |
| `DispatchContext` | Class | Exposes cooperative cancellation state for an incoming call. | Server implementation | Stopping server work after the caller sends `Finish` or the connection closes. |
| `TailCall` | Class | Describes forwarding the current dispatch result directly from another capability call. | Server implementation | Enabling the Level 1 tail-call wire optimization by overriding `Capability.tryTailCall`. |
| `CapCall` | Abstract interface class | Represents an in-progress call, exposing its eventual result and capabilities pipelined from result fields. | Generated code | Implementing generated pipeline objects that can issue calls before the original round trip completes. |
| `requireCapabilityFromResult` | Function | Resolves a capability from a top-level result pointer slot and throws `RpcException` if it cannot be resolved. | Generated code | Turning an interface-valued result field into a callable capability for local pipelining. |
| `vendCapabilityHandle` | Function | Returns an independently disposable, reference-counted handle to a capability. | Generated code | Allowing multiple readers or pipeline paths to own the same underlying capability safely. |

## Errors

| Symbol | Kind | What it does | Consumers | Primary use case(s) |
|---|---|---|---|---|
| `RpcException` | Class | Specializes `CapnpException` for connection, dispatch, remote, and protocol failures while retaining an `ErrorKind`. | Both | Reporting and handling failed calls, unsupported methods, cancellation, and disconnection. |

## Usage Boundaries

- A typical client uses `RpcSystem.connect`, calls `RpcConnection.bootstrap` with a generated capability factory, invokes typed generated methods, and eventually closes the connection and disposes retained capabilities.
- A typical server implements a generated capability server class, returns `DispatchResult`/`RpcPayload` through generated helpers, and passes its bootstrap capability to `RpcSystem.serve`.
- `Capability`, `CapabilityFactory`, `CapCall`, and most dispatch/result helpers are public primarily because generated code must refer to them. Application code normally uses the generated typed surface instead.
- Every capability reference has an ownership lifetime. Dispose retained capabilities when they are no longer needed; `vendCapabilityHandle` exists for runtime and generated-code paths that need independent ownership of the same target.
- `DispatchContext` cancellation is cooperative: a server must check `isCanceled`, await `canceled`, or call `throwIfCanceled` to stop its own work.
- `RpcPayload.fromEnvelope` and `RpcPayload.fromBuilder` are zero-copy views. Their backing message or builder must not be mutated while the payload is in use; use `bytes` only when a standalone serialized representation is required.
- `RpcSystem` is the high-level transport entry point. The concrete two-party connection implementation is intentionally not exported; custom transports require an API extension rather than depending on an internal class.
- Streaming backpressure is configured through `RpcSystem.connect`/`RpcSystem.serve`'s `streamWindowSize` option; its flow controller is an internal runtime detail.
