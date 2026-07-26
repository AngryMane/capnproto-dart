#!/usr/bin/env bash
# Publish every Dart package under packages/ and dev_packages/ to pub.dev.
#
# Usage:
#   ci/publish-packages.sh --dry-run  # validate without publishing
#   ci/publish-packages.sh            # publish non-interactively

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ci/publish-packages.sh [--dry-run]

Options:
  --dry-run  Run `dart pub publish --dry-run` for every package.
  -h, --help Show this help.
USAGE
}

DRY_RUN=false
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

if (($# > 1)); then
  usage >&2
  exit 64
fi

if ! command -v dart >/dev/null 2>&1; then
  echo "error: dart is not available on PATH" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Dependency order: repository dependencies must be published first.
PACKAGE_DIRS=(
  "packages/capnproto_dart"
  "packages/capnproto_dart_rpc"
  "dev_packages/capnpc-dart"
  "dev_packages/capnpc-dart-builder"
)

for relative_dir in "${PACKAGE_DIRS[@]}"; do
  pubspec="$REPO_ROOT/$relative_dir/pubspec.yaml"
  if [[ ! -f "$pubspec" ]]; then
    echo "error: package pubspec not found: $pubspec" >&2
    exit 1
  fi
done

for relative_dir in "${PACKAGE_DIRS[@]}"; do
  package_dir="$REPO_ROOT/$relative_dir"
  package_name="$(sed -n 's/^name:[[:space:]]*//p' "$package_dir/pubspec.yaml" | head -n 1)"
  if [[ -z "$package_name" ]]; then
    echo "error: package name not found in $relative_dir/pubspec.yaml" >&2
    exit 1
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "==> Validating $package_name ($relative_dir)"
    (cd "$package_dir" && dart pub publish --dry-run)
  else
    echo "==> Publishing $package_name ($relative_dir)"
    (cd "$package_dir" && dart pub publish --force)
  fi
done

if [[ "$DRY_RUN" == true ]]; then
  echo "All Dart packages passed pub publish validation."
else
  echo "All Dart packages were published successfully."
fi
