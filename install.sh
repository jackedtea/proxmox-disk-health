#!/usr/bin/env bash
#
# install.sh
# Downloads Disk Health Monitor from GitHub and installs it on Proxmox VE.
#
# Usage (on the Proxmox node, as root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jackedtea/proxmox-disk-health/main/install.sh)"
#
# Optional environment variables:
#   GITHUB_REPO  user/repo on GitHub          (default: jackedtea/proxmox-disk-health)
#   GITHUB_REF   branch, tag or commit hash   (default: main)
#   SUBDIR       subdirectory holding files   (default: repo root)

set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-jackedtea/proxmox-disk-health}"
GITHUB_REF="${GITHUB_REF:-main}"
SUBDIR="${SUBDIR:-}"
BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}${SUBDIR:+/${SUBDIR%/}}"

TIMERS=(disk-health-check disk-health-report disk-selftest-short disk-selftest-long)
UNIT_FILES=()
for t in "${TIMERS[@]}"; do UNIT_FILES+=("$t.service" "$t.timer"); done

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must run as root (try: sudo bash install.sh)" >&2
    exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required. Install it with: apt install curl" >&2; exit 1; }

echo ">> Source: ${BASE_URL}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo ">> [1/5] Checking smartmontools..."
if command -v smartctl >/dev/null 2>&1; then
    echo "   Already installed."
else
    apt-get update -qq
    apt-get install -y smartmontools
fi

echo ">> [2/5] Downloading files..."
for f in disk-health-monitor.sh "${UNIT_FILES[@]}"; do
    echo "   - ${f}"
    curl -fsSL "${BASE_URL}/${f}" -o "${TMP_DIR}/${f}" || { echo "Error: failed to download ${BASE_URL}/${f}" >&2; exit 1; }
done

echo ">> [3/5] Installing script to /usr/local/bin ..."
install -o root -g root -m 755 "${TMP_DIR}/disk-health-monitor.sh" /usr/local/bin/disk-health-monitor.sh

echo ">> [4/5] Installing systemd units to /etc/systemd/system ..."
for unit in "${UNIT_FILES[@]}"; do
    install -o root -g root -m 644 "${TMP_DIR}/${unit}" "/etc/systemd/system/${unit}"
done
systemctl daemon-reload

echo ">> [5/5] Enabling timers..."
# restart (not just enable --now) so schedule changes apply on re-install
systemctl enable "${TIMERS[@]/%/.timer}"
systemctl restart "${TIMERS[@]/%/.timer}"

cat <<EOF

==================================================================
 Installation complete!
==================================================================

Active timers:
$(systemctl list-timers 'disk-*' --no-pager 2>/dev/null || true)

Try it now:
  /usr/local/bin/disk-health-monitor.sh check

IMPORTANT: make sure Datacenter -> Notifications has at least one
target/matcher matching type=system-mail (and root@pam has a valid email).
See README.md in the repo if this is not configured yet.
EOF
