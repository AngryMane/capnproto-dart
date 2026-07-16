#!/usr/bin/env bash
# Update the capnp / capnp-rpc / capnpc crate version in every Rust sub-project.
#
# Usage:
#   ci/update-capnp-version.sh <minor>   e.g.  ci/update-capnp-version.sh 0.26
#
# The minor version string (e.g. "0.19") is written as the Cargo version
# requirement, which Cargo resolves to the latest available 0.19.x patch.
# After running this script, commit the Cargo.toml changes (or leave them
# unstaged in CI — the repo itself always contains the current working version).

set -euo pipefail

MINOR=${1:-}
if [[ -z "$MINOR" ]]; then
  echo "Usage: $0 <minor-version>  (e.g. 0.19)" >&2
  exit 1
fi

# All Rust sub-projects that depend on the capnp crate family.
CARGO_DIRS=(
  "sample/greeter/server"
  "sample/complex/server"
  "sample/complex/rust-client"
)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for rel in "${CARGO_DIRS[@]}"; do
  dir="$REPO_ROOT/$rel"
  toml="$dir/Cargo.toml"
  echo "  $rel → capnp $MINOR"
  # Replace the quoted version for each crate while keeping surrounding syntax intact.
  # Patterns are intentionally specific to avoid matching unrelated crates.
  sed -i \
    -e "s/\(capnp = \"\)[0-9]*\.[0-9]*/\1$MINOR/" \
    -e "s/\(capnp-rpc = \"\)[0-9]*\.[0-9]*/\1$MINOR/" \
    -e "s/\(capnpc = \"\)[0-9]*\.[0-9]*/\1$MINOR/" \
    "$toml"
done

echo "Done. Run 'cargo build' in each sub-project to fetch the updated crates."
