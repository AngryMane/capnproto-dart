#!/usr/bin/env bash
set -euo pipefail

# Runs inside the container (as root) via devcontainer.json's
# postStartCommand, on every start. OpenSSH's strict-mode ownership check
# rejects ~/.ssh/config unless it's owned by uid 0 or the calling user, but
# the host file bind-mounted at /run/host-ssh-config is owned by the host
# user. `cat` into a fresh file rather than `cp`/chown so the host-owned,
# read-only bind mount itself is never touched — only a root-owned copy is
# written inside the container.

readonly src="/run/host-ssh-config"
readonly dest="/root/.ssh/config"

install -d -m 700 /root/.ssh
cat "${src}" > "${dest}"
chmod 600 "${dest}"
