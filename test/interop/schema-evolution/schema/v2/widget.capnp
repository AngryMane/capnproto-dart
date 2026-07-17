@0xc2d4b6f80a123457;

# Schema-evolution fixture: "after" version.
#
# Same struct as ../v1/widget.capnp, field-for-field compatible: fields 0-2
# are unchanged, fields 3-5 are new appends (never renumbering or retyping an
# existing field, per the Cap'n Proto compatibility rules). See
# sample/schema-evolution for how this is used to cross-check Dart<->Rust
# forward/backward compatibility at runtime.

struct Widget {
  id @0 :UInt64;
  name @1 :Text;
  color @2 :Text;
  weight @3 :Float64 = 1.0;
  tags @4 :List(Text);
  status @5 :Status = active;
}

enum Status {
  active @0;
  discontinued @1;
}
