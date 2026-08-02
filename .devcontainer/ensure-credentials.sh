#!/usr/bin/env bash
set -euo pipefail

# Runs on the HOST via devcontainer.json's initializeCommand, before the
# container exists. devcontainer.json bind-mounts ~/.claude/.credentials.json
# and ~/.codex/auth.json read-only into the container; Docker refuses to
# create a bind mount whose source is missing, so make sure both files exist
# first (empty is fine — sync-credentials.sh only copies a file that isn't
# empty into the container). Idempotent — safe to run on every container
# (re)build/start.

readonly claude_credentials="${HOME}/.claude/.credentials.json"
readonly codex_auth="${HOME}/.codex/auth.json"

install -d -m 700 "${HOME}/.claude"
[[ -e "${claude_credentials}" ]] || install -m 600 /dev/null "${claude_credentials}"

install -d -m 700 "${HOME}/.codex"
[[ -e "${codex_auth}" ]] || install -m 600 /dev/null "${codex_auth}"
