#!/usr/bin/env bash
# Full test suite for the capnproto-dart project.
#
# Usage:
#   ci/run-tests.sh
#
# Run from the repository root.  Exit code 0 = all passed, 1 = any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

# ── helpers ─────────────────────────────────────────────────────────────────

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

pass() { PASS=$((PASS + 1)); green "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); red  "  FAIL: $*"; }

# Wait up to 10 s for a TCP port to accept connections.
wait_for_port() {
  local host=$1 port=$2
  for i in $(seq 1 20); do
    if bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for $host:$port" >&2
  return 1
}

run_section() {
  local title=$1
  printf '\n── %s ──\n' "$title"
}

# ── 1. Dart unit tests ───────────────────────────────────────────────────────

run_section "Dart unit tests: capnproto_dart"
if (cd packages/capnproto_dart && dart pub get && dart test); then
  pass "capnproto_dart unit tests"
else
  fail "capnproto_dart unit tests"
fi

run_section "Dart unit tests: capnproto_dart_rpc"
if (cd packages/capnproto_dart_rpc && dart pub get && dart test); then
  pass "capnproto_dart_rpc unit tests"
else
  fail "capnproto_dart_rpc unit tests"
fi

# ── 2. Greeter sample (Rust server + Dart client) ───────────────────────────

run_section "Greeter: build Rust server"
if cargo build --manifest-path sample/greeter/server/Cargo.toml --release 2>&1; then
  pass "greeter server build"
else
  fail "greeter server build"; goto_summary=1
fi

if [[ -z "${goto_summary:-}" ]]; then
  run_section "Greeter: integration test"
  ./sample/greeter/server/target/release/greeter-server &
  GREETER_PID=$!
  trap 'kill $GREETER_PID 2>/dev/null || true' EXIT

  if wait_for_port 127.0.0.1 12345; then
    if (cd sample/greeter/client && dart pub get && dart run bin/main.dart); then
      pass "greeter integration (Rust server + Dart client)"
    else
      fail "greeter integration (Rust server + Dart client)"
    fi
  else
    fail "greeter server did not start"
  fi

  kill $GREETER_PID 2>/dev/null || true
  trap - EXIT
fi

# ── 3. Complex sample: Rust server + Dart client ────────────────────────────

run_section "Complex: build Rust server"
if cargo build --manifest-path test/interop/complex/server/Cargo.toml --release 2>&1; then
  pass "complex server build"
else
  fail "complex server build"; goto_summary2=1
fi

if [[ -z "${goto_summary2:-}" ]]; then
  run_section "Complex: integration test (Rust server + Dart client)"
  ./test/interop/complex/server/target/release/complex-server &
  COMPLEX_SERVER_PID=$!
  trap 'kill $COMPLEX_SERVER_PID 2>/dev/null || true' EXIT

  if wait_for_port 127.0.0.1 12346; then
    if (cd test/interop/complex/client && dart pub get && dart run bin/main.dart); then
      pass "complex integration (Rust server + Dart client)"
    else
      fail "complex integration (Rust server + Dart client)"
    fi
  else
    fail "complex server did not start"
  fi

  kill $COMPLEX_SERVER_PID 2>/dev/null || true
  trap - EXIT
fi

# ── 4. Complex sample: Dart server + Rust client ────────────────────────────

run_section "Complex: build Rust client"
if cargo build --manifest-path test/interop/complex/rust-client/Cargo.toml --release 2>&1; then
  pass "complex rust-client build"
else
  fail "complex rust-client build"; goto_summary3=1
fi

if [[ -z "${goto_summary3:-}" ]]; then
  run_section "Complex: integration test (Dart server + Rust client)"
  (cd test/interop/complex/dart-server && dart pub get && dart run bin/main.dart) &
  DART_SERVER_PID=$!
  trap 'kill $DART_SERVER_PID 2>/dev/null || true' EXIT

  if wait_for_port 127.0.0.1 12347; then
    if ./test/interop/complex/rust-client/target/release/complex-rust-client; then
      pass "complex integration (Dart server + Rust client)"
    else
      fail "complex integration (Dart server + Rust client)"
    fi
  else
    fail "dart server did not start"
  fi

  kill $DART_SERVER_PID 2>/dev/null || true
  trap - EXIT
fi

# ── 5. Schema evolution: cross-language runtime compat ──────────────────────
#
# Proves — at runtime, not just by code review — that a message written by
# one language against an old schema is readable by the other language's
# newer schema (and vice versa), per Cap'n Proto's compatibility rules
# (fields only ever appended, never renumbered/retyped).

run_section "Schema evolution: build Rust binary"
if cargo build --manifest-path test/interop/schema-evolution/rust/Cargo.toml --release 2>&1; then
  pass "schema-evolution rust build"
else
  fail "schema-evolution rust build"; goto_summary4=1
fi

if [[ -z "${goto_summary4:-}" ]]; then
  run_section "Schema evolution: dart pub get"
  if (cd test/interop/schema-evolution/dart && dart pub get); then
    pass "schema-evolution dart pub get"
  else
    fail "schema-evolution dart pub get"; goto_summary4=1
  fi
fi

if [[ -z "${goto_summary4:-}" ]]; then
  run_section "Schema evolution: cross-language round-trip"
  SE_BIN="$REPO_ROOT/test/interop/schema-evolution/rust/target/release/schema-evolution-rust"
  se_dart() { (cd test/interop/schema-evolution/dart && dart run bin/main.dart "$@"); }
  SE_TMP="$(mktemp -d)"
  trap 'rm -rf "$SE_TMP"' EXIT

  if "$SE_BIN" write-v1 "$SE_TMP/rust_v1.bin" \
      && se_dart read-v2 "$SE_TMP/rust_v1.bin"; then
    pass "schema evolution: Rust writes v1, Dart reads v2"
  else
    fail "schema evolution: Rust writes v1, Dart reads v2"
  fi

  if se_dart write-v1 "$SE_TMP/dart_v1.bin" \
      && "$SE_BIN" read-v2 "$SE_TMP/dart_v1.bin"; then
    pass "schema evolution: Dart writes v1, Rust reads v2"
  else
    fail "schema evolution: Dart writes v1, Rust reads v2"
  fi

  if "$SE_BIN" write-v2 "$SE_TMP/rust_v2.bin" \
      && se_dart read-v1 "$SE_TMP/rust_v2.bin"; then
    pass "schema evolution: Rust writes v2, Dart reads v1"
  else
    fail "schema evolution: Rust writes v2, Dart reads v1"
  fi

  if se_dart write-v2 "$SE_TMP/dart_v2.bin" \
      && "$SE_BIN" read-v1 "$SE_TMP/dart_v2.bin"; then
    pass "schema evolution: Dart writes v2, Rust reads v1"
  else
    fail "schema evolution: Dart writes v2, Rust reads v1"
  fi

  rm -rf "$SE_TMP"
  trap - EXIT
fi

# ── 5b. F-08: capnpc-dart compatibility-check CLI against the real capnp CLI ─
#
# capnp's own `-o<lang>[:<dir>]` plugin syntax always treats everything after
# the first colon as an output directory, so `capnp compile -o dart:check=...`
# (this component's former documented invocation) can never actually reach
# capnpc-dart with a `check` option — capnp itself rejects it before the
# plugin even runs. The real mechanism is `capnp compile -o-` (dump the
# request to stdout) piped directly into the capnpc-dart binary, which reads
# ordinary argv flags. This section exercises that real end-to-end path
# against the actual `capnp` CLI.
#
# The compat checker correlates nodes by their Cap'n Proto node id, which is
# derived from the file's own `@0x...` id — so, unlike the schema-evolution
# runtime fixtures (which deliberately use two independently-versioned files,
# each with its own id), the old/new pair here must share one file id, as if
# it were the same schema file edited in place between commits.

run_section "F-08 compat-check: schema fixtures"
F08_TMP="$(mktemp -d)"
trap 'rm -rf "$F08_TMP"' EXIT
cat > "$F08_TMP/old.capnp" <<'EOF'
@0x9c4f478e91f1c34a;
struct Widget {
  id @0 :UInt64;
  name @1 :Text;
}
EOF
cat > "$F08_TMP/new_compatible.capnp" <<'EOF'
@0x9c4f478e91f1c34a;
struct Widget {
  id @0 :UInt64;
  name @1 :Text;
  color @2 :Text;
}
EOF
cat > "$F08_TMP/new_incompatible.capnp" <<'EOF'
@0x9c4f478e91f1c34a;
struct Widget {
  id @0 :Text;
  name @1 :Text;
}
EOF

run_section "F-08 compat-check: compatible change (appended field)"
if capnp compile -o- "$F08_TMP/new_compatible.capnp" \
    | dart run tools/capnpc-dart/bin/capnpc_dart.dart --check="$F08_TMP/old.capnp"; then
  pass "F-08: compatible change reports no incompatibilities"
else
  fail "F-08: compatible change reports no incompatibilities"
fi

run_section "F-08 compat-check: incompatible change (retyped field)"
if capnp compile -o- "$F08_TMP/new_incompatible.capnp" \
    | dart run tools/capnpc-dart/bin/capnpc_dart.dart --check="$F08_TMP/old.capnp"; then
  fail "F-08: incompatible change (retyped field) correctly rejected (exit 0, expected 1)"
else
  pass "F-08: incompatible change (retyped field) correctly rejected"
fi

# #55: interface method evolution rules, against the real capnp CLI output —
# same rationale as the struct fixtures above, but exercising the
# InterfaceBody branch (method removal, method addition).
cat > "$F08_TMP/old_iface.capnp" <<'EOF'
@0xa1b2c3d4e5f60718;
interface Widget {
  getName @0 () -> (name :Text);
  setName @1 (name :Text) -> ();
}
EOF
cat > "$F08_TMP/new_iface_compatible.capnp" <<'EOF'
@0xa1b2c3d4e5f60718;
interface Widget {
  getName @0 () -> (name :Text);
  setName @1 (name :Text) -> ();
  getId @2 () -> (id :UInt64);
}
EOF
cat > "$F08_TMP/new_iface_incompatible.capnp" <<'EOF'
@0xa1b2c3d4e5f60718;
interface Widget {
  getName @0 () -> (name :Text);
}
EOF

run_section "F-08 compat-check: compatible interface change (appended method)"
if capnp compile -o- "$F08_TMP/new_iface_compatible.capnp" \
    | dart run tools/capnpc-dart/bin/capnpc_dart.dart --check="$F08_TMP/old_iface.capnp"; then
  pass "F-08: compatible interface change reports no incompatibilities"
else
  fail "F-08: compatible interface change reports no incompatibilities"
fi

run_section "F-08 compat-check: incompatible interface change (removed method)"
if capnp compile -o- "$F08_TMP/new_iface_incompatible.capnp" \
    | dart run tools/capnpc-dart/bin/capnpc_dart.dart --check="$F08_TMP/old_iface.capnp"; then
  fail "F-08: incompatible interface change (removed method) correctly rejected (exit 0, expected 1)"
else
  pass "F-08: incompatible interface change (removed method) correctly rejected"
fi

rm -rf "$F08_TMP"
trap - EXIT

# ── 5c. #46: cross-file `using` imports + `const` declaration codegen ───────
#
# Both generate actual .capnp.dart *code* (unlike F-08's check-mode-only
# fixtures above), so the real proof is that `dart analyze` accepts the
# output — a passing string-matching unit test alone wouldn't catch e.g. a
# missing import that only breaks compilation, which is exactly the bug this
# regression test exists to catch.

run_section "#46: cross-file imports + const codegen — fixtures"
GEN46_TMP="$(mktemp -d)"
trap 'rm -rf "$GEN46_TMP"' EXIT

cat > "$GEN46_TMP/bar.capnp" <<'EOF'
@0xb1b2b3b4b5b6b7b1;
struct Bar {
  value @0 :UInt32;
}
EOF
cat > "$GEN46_TMP/foo.capnp" <<'EOF'
@0xf1f2f3f4f5f6f7f1;
using import "bar.capnp".Bar;
struct Foo {
  bar @0 :Bar;
}
EOF
cat > "$GEN46_TMP/consts.capnp" <<'EOF'
@0xc1c2c3c4c5c6c7c1;
struct Point {
  x @0 :Int32;
  y @1 :Int32;
}
enum Color {
  red @0;
  green @1;
  blue @2;
}
const maxSize :UInt32 = 100;
const ratio :Float64 = 1.5;
const greeting :Text = "hello";
const defaultColor :Color = blue;
const origin :Point = (x = 3, y = 4);
EOF
cat > "$GEN46_TMP/pubspec.yaml" <<EOF
name: gen46_check
environment:
  sdk: ^3.7.2
dependencies:
  capnproto_dart:
    path: $REPO_ROOT/packages/capnproto_dart
EOF
cat > "$GEN46_TMP/check_consts.dart" <<'EOF'
import 'consts.capnp.dart';

void main() {
  if (maxSize != 100) throw StateError('maxSize wrong: $maxSize');
  print('ok: maxSize = $maxSize');
  if (ratio != 1.5) throw StateError('ratio wrong: $ratio');
  print('ok: ratio = $ratio');
  if (greeting != 'hello') throw StateError('greeting wrong: $greeting');
  print('ok: greeting = $greeting');
  if (defaultColor != Color.blue) {
    throw StateError('defaultColor wrong: $defaultColor');
  }
  print('ok: defaultColor = $defaultColor');
  if (origin.x != 3 || origin.y != 4) {
    throw StateError('origin wrong: (${origin.x}, ${origin.y})');
  }
  print('ok: origin = (${origin.x}, ${origin.y})');
}
EOF

(
  cd "$GEN46_TMP"
  capnp compile -o- foo.capnp bar.capnp consts.capnp \
    | dart run "$REPO_ROOT/tools/capnpc-dart/bin/capnpc_dart.dart"
)

run_section "#46: cross-file using — generated code compiles"
# --no-fatal-warnings: this check is specifically about compile *errors*
# (does the generated code even build) — an unrelated lint warning on these
# deliberately minimal fixture schemas (e.g. an unused dart:typed_data
# import on a struct with no Data/List fields, a pre-existing generator
# quirk unrelated to #46) shouldn't fail a regression test that isn't about
# lint cleanliness.
if (cd "$GEN46_TMP" && dart pub get \
    && dart analyze --no-fatal-warnings foo.capnp.dart bar.capnp.dart); then
  pass "#46: foo.capnp.dart (using bar.capnp's Bar) analyzes cleanly"
else
  fail "#46: foo.capnp.dart (using bar.capnp's Bar) analyzes cleanly"
fi
if grep -q "import 'bar.capnp.dart';" "$GEN46_TMP/foo.capnp.dart"; then
  pass "#46: foo.capnp.dart imports bar.capnp.dart"
else
  fail "#46: foo.capnp.dart imports bar.capnp.dart"
fi

run_section "#46: const declarations — generated values match the schema"
if (cd "$GEN46_TMP" && dart run check_consts.dart); then
  pass "#46: generated const declarations have the correct runtime values"
else
  fail "#46: generated const declarations have the correct runtime values"
fi

rm -rf "$GEN46_TMP"
trap - EXIT

# ── 6. Wire-format golden test: official capnp CLI as oracle ────────────────
#
# Independent of RPC: proves this library's serializer/deserializer produce
# and consume bytes that are byte-for-byte interchangeable with the official
# C++ reference implementation (the `capnp` CLI itself, not another client of
# the spec). Three directions:
#   1. Dart encodes a message; `capnp decode --short` on Dart's bytes must
#      produce the exact same text as encoding+decoding an equivalent literal
#      entirely within the official implementation.
#   2. `capnp encode` builds a message from a hand-written literal; Dart must
#      decode the exact field values back out.
#   3. MessageReader.canonicalize() must match `capnp convert binary:canonical`
#      byte-for-byte on fixtures with default/null trailing fields.

run_section "Wire-format golden: dart pub get"
if (cd test/interop/wire-format-golden/dart && dart pub get); then
  pass "wire-format-golden dart pub get"
else
  fail "wire-format-golden dart pub get"; goto_summary5=1
fi

if [[ -z "${goto_summary5:-}" ]]; then
  run_section "Wire-format golden: cross-check against capnp CLI"
  WFG_SCHEMA="$REPO_ROOT/test/interop/wire-format-golden/schema/golden.capnp"
  WFG_TMP="$(mktemp -d)"
  trap 'rm -rf "$WFG_TMP"' EXIT
  wfg_dart() { (cd test/interop/wire-format-golden/dart && dart run bin/main.dart "$@"); }

  LITERAL_SCALARS='(boolean = true, int8Value = -8, int16Value = -1600, int32Value = -320000, int64Value = -6400000000, uint8Value = 8, uint16Value = 1600, uint32Value = 320000, uint64Value = 6400000000, float32Value = 1.25, float64Value = -2.5, textValue = "hello \"world\"", dataValue = 0x"00 01 02 03 7f 80 fe ff", color = green)'
  LITERAL_NESTED='(label = "root", values = [1, 2, 3], tags = ["a", "b"], children = [(label = "child1", values = [4], tags = [], children = []), (label = "child2", values = [], tags = ["x"], children = [])])'

  # Direction 1: Dart encode -> capnp decode, compared to capnp's own round-trip.
  golden_text=$(echo "$LITERAL_SCALARS" | capnp encode "$WFG_SCHEMA" AllScalars | capnp decode "$WFG_SCHEMA" AllScalars --short)
  wfg_dart encode-scalars "$WFG_TMP/scalars_dart.bin"
  dart_text=$(capnp decode "$WFG_SCHEMA" AllScalars --short < "$WFG_TMP/scalars_dart.bin")
  if [[ "$golden_text" == "$dart_text" ]]; then
    pass "wire-format golden: Dart-encoded AllScalars matches capnp decode text"
  else
    fail "wire-format golden: Dart-encoded AllScalars matches capnp decode text (got: $dart_text)"
  fi

  golden_text=$(echo "$LITERAL_NESTED" | capnp encode "$WFG_SCHEMA" Nested | capnp decode "$WFG_SCHEMA" Nested --short)
  wfg_dart encode-nested "$WFG_TMP/nested_dart.bin"
  dart_text=$(capnp decode "$WFG_SCHEMA" Nested --short < "$WFG_TMP/nested_dart.bin")
  if [[ "$golden_text" == "$dart_text" ]]; then
    pass "wire-format golden: Dart-encoded Nested matches capnp decode text"
  else
    fail "wire-format golden: Dart-encoded Nested matches capnp decode text (got: $dart_text)"
  fi

  # Direction 2: capnp encode -> Dart decode.
  echo "$LITERAL_SCALARS" | capnp encode "$WFG_SCHEMA" AllScalars > "$WFG_TMP/scalars_capnp.bin"
  if wfg_dart decode-scalars "$WFG_TMP/scalars_capnp.bin"; then
    pass "wire-format golden: Dart decodes capnp-encoded AllScalars"
  else
    fail "wire-format golden: Dart decodes capnp-encoded AllScalars"
  fi

  echo "$LITERAL_NESTED" | capnp encode "$WFG_SCHEMA" Nested > "$WFG_TMP/nested_capnp.bin"
  if wfg_dart decode-nested "$WFG_TMP/nested_capnp.bin"; then
    pass "wire-format golden: Dart decodes capnp-encoded Nested"
  else
    fail "wire-format golden: Dart decodes capnp-encoded Nested"
  fi

  # Direction 3: canonicalization. `capnp convert binary:canonical` is the
  # reference implementation's canonical encoding; MessageReader.canonicalize()
  # must produce byte-for-byte identical output on the same input, including
  # fixtures that deliberately leave fields at their default/null value so
  # data-section and pointer-section trimming (and struct-list re-packing)
  # are actually exercised, not just round-tripped.
  wfg_canon() {
    local mode=$1 type=$2 name=$3
    wfg_dart "$mode" "$WFG_TMP/$name.bin"
    wfg_dart canonicalize "$WFG_TMP/$name.bin" "$WFG_TMP/$name.dart.canonical"
    capnp convert binary:canonical "$WFG_SCHEMA" "$type" < "$WFG_TMP/$name.bin" > "$WFG_TMP/$name.capnp.canonical"
    if cmp -s "$WFG_TMP/$name.dart.canonical" "$WFG_TMP/$name.capnp.canonical"; then
      pass "wire-format golden: canonicalize $name matches capnp convert binary:canonical"
    else
      fail "wire-format golden: canonicalize $name matches capnp convert binary:canonical"
    fi
  }
  wfg_canon encode-scalars-sparse AllScalars scalars_sparse
  wfg_canon encode-sparse Nested sparse
  wfg_canon encode-children Nested children
  wfg_canon encode-nested Nested nested

  rm -rf "$WFG_TMP"
  trap - EXIT
fi

# ── Summary ─────────────────────────────────────────────────────────────────

printf '\n══════════════════════════════════════\n'
printf 'PASSED: %d   FAILED: %d\n' "$PASS" "$FAIL"
printf '══════════════════════════════════════\n'

[[ $FAIL -eq 0 ]]
