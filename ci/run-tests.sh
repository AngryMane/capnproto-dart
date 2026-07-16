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
if (cd packages/capnproto_dart && dart pub get -q && dart test); then
  pass "capnproto_dart unit tests"
else
  fail "capnproto_dart unit tests"
fi

run_section "Dart unit tests: capnproto_dart_rpc"
if (cd packages/capnproto_dart_rpc && dart pub get -q && dart test); then
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
    if (cd sample/greeter/client && dart pub get -q && dart run bin/main.dart); then
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
    if (cd sample/complex/client && dart pub get -q && dart run bin/main.dart); then
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
  (cd sample/complex/dart-server && dart pub get -q && dart run bin/main.dart) &
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

# ── Summary ─────────────────────────────────────────────────────────────────

printf '\n══════════════════════════════════════\n'
printf 'PASSED: %d   FAILED: %d\n' "$PASS" "$FAIL"
printf '══════════════════════════════════════\n'

[[ $FAIL -eq 0 ]]
