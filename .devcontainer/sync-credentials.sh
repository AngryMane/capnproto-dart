#!/usr/bin/env bash
set -euo pipefail

# Runs inside the container (as root) via devcontainer.json's
# postStartCommand, on every start. Claude Code / Codex credentials are
# meant to be a one-way bridge from host to container (see the mounts
# comment in devcontainer.json) — logging in inside the container must
# never write back to the host's credential file. The host files are
# staged read-only at /run/host-credentials/*, and copied here into the
# container-local volumes (capnproto-dart-claude-home /
# capnproto-dart-codex-home) so any login performed inside the container
# only ever updates the local copy.

install -d -m 700 /root/.claude /root/.codex

# ensure-credentials.sh (host-side) creates these staging files even when the
# user has no credentials yet, so they exist for the bind mount — that shows
# up here as an empty file. Skip copying in that case rather than clobbering
# a credential the container already obtained via its own `claude`/`codex`
# login on a previous start.
if [[ -s /run/host-credentials/claude.json ]]; then
    cat /run/host-credentials/claude.json > /root/.claude/.credentials.json
    chmod 600 /root/.claude/.credentials.json
fi

if [[ -s /run/host-credentials/codex.json ]]; then
    cat /run/host-credentials/codex.json > /root/.codex/auth.json
    chmod 600 /root/.codex/auth.json
fi
