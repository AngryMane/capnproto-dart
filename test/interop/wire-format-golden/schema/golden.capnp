@0xe4a1c6f2b8d05913;

# Wire-format golden-test fixture.
#
# Used by sample/wire-format-golden to prove — independent of RPC — that this
# repository's serializer/deserializer produces and consumes bytes that are
# byte-for-byte interchangeable with the official C++ capnp reference
# implementation (the `capnp` CLI), which is the most authoritative oracle
# available: it *is* the specification, not just another client of it.

struct AllScalars {
  boolean @0 :Bool;

  int8Value @1 :Int8;
  int16Value @2 :Int16;
  int32Value @3 :Int32;
  int64Value @4 :Int64;

  uint8Value @5 :UInt8;
  uint16Value @6 :UInt16;
  uint32Value @7 :UInt32;
  uint64Value @8 :UInt64;

  float32Value @9 :Float32;
  float64Value @10 :Float64;

  textValue @11 :Text;
  dataValue @12 :Data;
  color @13 :Color;
}

enum Color {
  red @0;
  green @1;
  blue @2;
}

# Recursive struct with a composite (struct) list and a primitive list, to
# cover pointer-section encoding (far pointers, composite list tags) that
# AllScalars — being pointer-light — doesn't exercise.
struct Nested {
  label @0 :Text;
  values @1 :List(Int32);
  tags @2 :List(Text);
  children @3 :List(Nested);
}
