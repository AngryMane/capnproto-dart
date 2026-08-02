#!/usr/bin/env bash
set -euo pipefail

# Runs on the HOST via devcontainer.json's initializeCommand, before the
# container exists. Starts (or reuses) a systemd --user service that owns the
# notification socket the container will bind-mount read-only. Idempotent —
# safe to run on every container (re)build/start.

if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

readonly unit_name="capnproto-dart-notify-relay"
readonly runtime_dir="${XDG_RUNTIME_DIR}/capnproto-dart-notify"
readonly socket_path="${runtime_dir}/notify.sock"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly relay_script="${script_dir}/host_relay.py"

command -v systemd-run >/dev/null || {
    echo "systemd-run is required on the Ubuntu host" >&2
    exit 1
}

command -v notify-send >/dev/null || {
    echo "Install notify-send on the host: sudo apt install libnotify-bin" >&2
    exit 1
}

install -d -m 700 "${runtime_dir}"

if systemctl --user is-active --quiet "${unit_name}.service"; then
    exit 0
fi

systemctl --user stop "${unit_name}.service" 2>/dev/null || true
rm -f "${socket_path}"

systemd-run \
    --user \
    --collect \
    --unit="${unit_name}" \
    --property=Restart=on-failure \
    --property=RestartSec=1 \
    /usr/bin/python3 "${relay_script}" "${socket_path}"

for _ in {1..50}; do
    [[ -S "${socket_path}" ]] && exit 0
    sleep 0.1
done

echo "Notification relay did not create ${socket_path}" >&2
systemctl --user status "${unit_name}.service" --no-pager >&2 || true
exit 1
