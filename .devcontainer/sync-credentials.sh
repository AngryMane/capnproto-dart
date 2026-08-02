#!/usr/bin/env bash
set -euo pipefail

# Runs inside the container (as root) via devcontainer.json's
# postStartCommand, on every start. Claude Code / Codex credentials are
# meant to be a one-way bridge from host to container (see the mounts
# comment in devcontainer.json) — logging in inside the container must
# never write back to the host's credential file. The host files are
# staged read-only at /run/host-credentials/*, and seed the container-local
# volumes (capnproto-dart-claude-home / capnproto-dart-codex-home) the first
# time only: once the container has its own credential (from this seed or
# from a `claude`/`codex login` run inside the container), later starts
# leave it alone, so a token refreshed or re-logged-in inside the container
# survives across restarts instead of being overwritten by a stale host copy
# on the next start.

install -d -m 700 /root/.claude /root/.codex

if [[ ! -s /root/.claude/.credentials.json && -s /run/host-credentials/claude.json ]]; then
    install -m 600 /run/host-credentials/claude.json /root/.claude/.credentials.json
fi

if [[ ! -s /root/.codex/auth.json && -s /run/host-credentials/codex.json ]]; then
    install -m 600 /run/host-credentials/codex.json /root/.codex/auth.json
fi
