#!/usr/bin/env bash
set -euo pipefail

# Runs on the HOST via devcontainer.json's initializeCommand, before the
# container exists. devcontainer.json bind-mounts ~/.ssh/config and
# ~/.ssh/known_hosts read-only into the container; Docker refuses to create a
# bind mount whose source is missing, so make sure both files exist first.
# Also bind-mounts the host's ssh-agent socket, whose path comes from
# SSH_AUTH_SOCK — fail with a clear message rather than the opaque Docker
# error that follows from an empty/invalid mount source. Idempotent — safe to
# run on every container (re)build/start.

readonly ssh_dir="${HOME}/.ssh"
readonly config_path="${ssh_dir}/config"
readonly known_hosts_path="${ssh_dir}/known_hosts"

install -d -m 700 "${ssh_dir}"
[[ -e "${config_path}" ]] || install -m 600 /dev/null "${config_path}"
[[ -e "${known_hosts_path}" ]] || install -m 600 /dev/null "${known_hosts_path}"

if [[ -z "${SSH_AUTH_SOCK:-}" || ! -S "${SSH_AUTH_SOCK}" ]]; then
    echo "SSH_AUTH_SOCK is not set or is not a Unix socket." >&2
    echo "Start ssh-agent and add the required key before opening the devcontainer." >&2
    exit 1
fi
