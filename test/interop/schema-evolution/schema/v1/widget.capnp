@0xb1c3a5e7f9012346;

# Schema-evolution fixture: "before" version.
#
# Used by sample/schema-evolution to prove — at runtime, across languages —
# that Cap'n Proto's wire-compatibility guarantees actually hold in this
# implementation: a message written by one language against this schema must
# be readable by the other language's v2-generated code (see ../v2/widget.capnp),
# with new fields resolving to their declared defaults.

struct Widget {
  id @0 :UInt64;
  name @1 :Text;
  color @2 :Text;
}
