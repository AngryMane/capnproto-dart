#!/usr/bin/env bash
set -euo pipefail

# Runs on the HOST via devcontainer.json's initializeCommand, before the
# container exists. devcontainer.json bind-mounts ~/.ssh/config read-only into
# the container; Docker refuses to create a bind mount whose source is
# missing, so make sure the file exists first. Idempotent — safe to run on
# every container (re)build/start.

readonly ssh_dir="${HOME}/.ssh"
readonly config_path="${ssh_dir}/config"

install -d -m 700 "${ssh_dir}"
[[ -e "${config_path}" ]] || install -m 600 /dev/null "${config_path}"
