@0xdaed30c590765bc3;

# Mirrors the hand-written `_MetricsReader`/`_MetricsBuilder` struct in
# packages/capnproto_dart/benchmark/serialization_benchmark.dart field for
# field, so the Dart and Rust serialization benchmarks encode/decode the
# same shape and are directly comparable.
struct Metrics {
  flag @0 :Bool;
  count @1 :Int32;
  total @2 :Int64;
  ratio @3 :Float64;
  label @4 :Text;
}
