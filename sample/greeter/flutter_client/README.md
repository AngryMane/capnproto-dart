# greeter_flutter_client

Flutter (Linux desktop) client for the [Greeter sample](../schema/greeter.capnp),
demonstrating Dart↔Rust Cap'n Proto RPC interop from a GUI app instead of the
console-based [`../client`](../client).

## Run

Start the Rust server, then run this app targeting Linux desktop:

```sh
cargo run --manifest-path ../server/Cargo.toml
flutter run -d linux
```

Enter a name and use the buttons to call `greet()` (one-shot) or
`newSession()` followed by `session.greet()` (capability-passing), same as
the console client.
