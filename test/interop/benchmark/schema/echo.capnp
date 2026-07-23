@0xdd9b5a085eb6ad24;

# Mirrors the hand-rolled Echo capability (interfaceId 0x0001, methodId 0)
# in packages/capnproto_dart_rpc/benchmark/rpc_benchmark.dart, so the Dart
# and Rust RPC benchmarks measure the same call shape and are directly
# comparable.
interface Echo {
  echo @0 (message :Text) -> (message :Text);
}
