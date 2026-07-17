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
if cargo build --manifest-path sample/complex/server/Cargo.toml --release 2>&1; then
  pass "complex server build"
else
  fail "complex server build"; goto_summary2=1
fi

if [[ -z "${goto_summary2:-}" ]]; then
  run_section "Complex: integration test (Rust server + Dart client)"
  ./sample/complex/server/target/release/complex-server &
  COMPLEX_SERVER_PID=$!
  trap 'kill $COMPLEX_SERVER_PID 2>/dev/null || true' EXIT

  if wait_for_port 127.0.0.1 12346; then
    if (cd sample/complex/client && dart pub get && dart run bin/main.dart); then
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
if cargo build --manifest-path sample/complex/rust-client/Cargo.toml --release 2>&1; then
  pass "complex rust-client build"
else
  fail "complex rust-client build"; goto_summary3=1
fi

if [[ -z "${goto_summary3:-}" ]]; then
  run_section "Complex: integration test (Dart server + Rust client)"
  (cd sample/complex/dart-server && dart pub get && dart run bin/main.dart) &
  DART_SERVER_PID=$!
  trap 'kill $DART_SERVER_PID 2>/dev/null || true' EXIT

  if wait_for_port 127.0.0.1 12347; then
    if ./sample/complex/rust-client/target/release/complex-rust-client; then
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
if cargo build --manifest-path sample/schema-evolution/rust/Cargo.toml --release 2>&1; then
  pass "schema-evolution rust build"
else
  fail "schema-evolution rust build"; goto_summary4=1
fi

if [[ -z "${goto_summary4:-}" ]]; then
  run_section "Schema evolution: dart pub get"
  if (cd sample/schema-evolution/dart && dart pub get); then
    pass "schema-evolution dart pub get"
  else
    fail "schema-evolution dart pub get"; goto_summary4=1
  fi
fi

if [[ -z "${goto_summary4:-}" ]]; then
  run_section "Schema evolution: cross-language round-trip"
  SE_BIN="$REPO_ROOT/sample/schema-evolution/rust/target/release/schema-evolution-rust"
  se_dart() { (cd sample/schema-evolution/dart && dart run bin/main.dart "$@"); }
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

# ── 6. Wire-format golden test: official capnp CLI as oracle ────────────────
#
# Independent of RPC: proves this library's serializer/deserializer produce
# and consume bytes that are byte-for-byte interchangeable with the official
# C++ reference implementation (the `capnp` CLI itself, not another client of
# the spec). Two directions:
#   1. Dart encodes a message; `capnp decode --short` on Dart's bytes must
#      produce the exact same text as encoding+decoding an equivalent literal
#      entirely within the official implementation.
#   2. `capnp encode` builds a message from a hand-written literal; Dart must
#      decode the exact field values back out.

run_section "Wire-format golden: dart pub get"
if (cd sample/wire-format-golden/dart && dart pub get); then
  pass "wire-format-golden dart pub get"
else
  fail "wire-format-golden dart pub get"; goto_summary5=1
fi

if [[ -z "${goto_summary5:-}" ]]; then
  run_section "Wire-format golden: cross-check against capnp CLI"
  WFG_SCHEMA="$REPO_ROOT/sample/wire-format-golden/schema/golden.capnp"
  WFG_TMP="$(mktemp -d)"
  trap 'rm -rf "$WFG_TMP"' EXIT
  wfg_dart() { (cd sample/wire-format-golden/dart && dart run bin/main.dart "$@"); }

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

  rm -rf "$WFG_TMP"
  trap - EXIT
fi

# ── Summary ─────────────────────────────────────────────────────────────────

printf '\n══════════════════════════════════════\n'
printf 'PASSED: %d   FAILED: %d\n' "$PASS" "$FAIL"
printf '══════════════════════════════════════\n'

[[ $FAIL -eq 0 ]]
