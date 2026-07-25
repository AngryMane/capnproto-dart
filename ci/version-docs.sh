#!/usr/bin/env bash
# Freeze a versioned snapshot of every docs site section for a release.
#
# Usage:
#   ci/version-docs.sh <version>   e.g.  ci/version-docs.sh 0.2.0
#
# Runs `docusaurus docs:version:<id> <version>` for each plugin-content-docs instance
# declared in website/docusaurus.config.js (currently just root docs/), producing
# website/<id>_versioned_docs/version-<version>/,
# website/<id>_versioned_sidebars/version-<version>-sidebars.json, and an updated
# website/<id>_versions.json for each. Commit the result to publish the snapshot.
#
# Used by .github/workflows/docs-version.yml on every `vX.Y.Z` tag push; also runnable
# locally to preview a snapshot before tagging (`ci/version-docs.sh <version> && cd
# website && npm start`).

set -euo pipefail

VERSION=${1:-}
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>  (e.g. 0.2.0)" >&2
  exit 1
fi

# Plugin ids declared in website/docusaurus.config.js.
PLUGIN_IDS=(
  "root"
)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for id in "${PLUGIN_IDS[@]}"; do
  echo "  $id → version $VERSION"
  (cd "$REPO_ROOT/website" && npx docusaurus "docs:version:$id" "$VERSION")
done

echo "Done. Review website/*_versioned_docs, then commit to publish the snapshot."
