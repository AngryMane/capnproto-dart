# External Spec: RPC Runtime (`capnproto_dart_rpc`)

A pure Dart library implements **Cap'n Proto RPC Level 1** with no FFI dependencies.  
Simply put, this library implements functionality substantially equivalent to the Rust implementation of Cap'n Proto.  
Any Level 2 or Level 3 features are not supported so far.  
This library depends on the [Serialization Runtime (`capnproto_dart`)](pathname:///capnproto_dart/external-spec) for message encoding.  

## Feature

This library lets your Dart application call methods on objects that live in another
process, over a network connection — Cap'n Proto RPC.

```dart
final connection = await RpcSystem.connect(uri);
final foo = connection.bootstrap(FooFactory());
final result = await foo.getBar();
```

Promise pipelining, tail calls, and Resolve/Disembargo are part of the Cap'n Proto RPC
protocol itself; see the [Cap'n Proto RPC protocol](https://capnproto.org/rpc.html) for
how they work.

This library implements **Cap'n Proto RPC Level 1** only. If a peer requires something
beyond that (e.g. three-party handoff, persistent capabilities), the connection closes
with a clear error instead of behaving incorrectly.

## Interface
