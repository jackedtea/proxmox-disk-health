#!/usr/bin/env bash
#
# install.sh
# Tai toan bo file cua Disk Health Monitor tu GitHub va cai dat tren Proxmox VE.
#
# Cach dung (chay tren node Proxmox, can quyen root):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install.sh)"
#
# Hoac tai ve roi chay:
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install.sh -o install.sh
#   sudo bash install.sh

set -euo pipefail

# ================= CAU HINH: SUA LAI CHO DUNG REPO CUA BAN =================
GITHUB_REPO="${GITHUB_REPO:-your-username/your-repo}"   # vd: "anhvan/disk-health-monitor"
GITHUB_REF="${GITHUB_REF:-main}"                          # nhanh (branch) hoac tag/commit cu the
SUBDIR="${SUBDIR:-}"                                       # thu muc con trong repo chua cac file, de trong neu o root repo
# =============================================================================

BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}"
[[ -n "$SUBDIR" ]] && BASE_URL="${BASE_URL}/${SUBDIR}"

FILES=(
    "disk-health-monitor.sh"
    "disk-health-check.service"
    "disk-health-check.timer"
    "disk-health-report.service"
    "disk-health-report.timer"
    "disk-selftest-short.service"
    "disk-selftest-short.timer"
    "disk-selftest-long.service"
    "disk-selftest-long.timer"
)

UNIT_FILES=(
    "disk-health-check.service"
    "disk-health-check.timer"
    "disk-health-report.service"
    "disk-health-report.timer"
    "disk-selftest-short.service"
    "disk-selftest-short.timer"
    "disk-selftest-long.service"
    "disk-selftest-long.timer"
)

# ------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Loi: script nay can chay voi quyen root (thu: sudo bash install.sh)" >&2
    exit 1
fi

if [[ "$GITHUB_REPO" == "your-username/your-repo" ]]; then
    echo "Loi: chua cau hinh GITHUB_REPO." >&2
    echo "Sua bien GITHUB_REPO o dau file install.sh, hoac chay voi:" >&2
    echo "  GITHUB_REPO=\"user/repo\" sudo -E bash install.sh" >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "Loi: can co curl. Cai dat: apt install curl" >&2; exit 1; }

echo ">> Nguon tai file: ${BASE_URL}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo ">> [1/5] Kiem tra / cai dat smartmontools..."
if ! command -v smartctl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y smartmontools
else
    echo "   Da co san."
fi

echo ">> [2/5] Tai file tu GitHub..."
for f in "${FILES[@]}"; do
    echo "   - ${f}"
    if ! curl -fsSL "${BASE_URL}/${f}" -o "${TMP_DIR}/${f}"; then
        echo "Loi: khong tai duoc ${BASE_URL}/${f}" >&2
        echo "Kiem tra lai GITHUB_REPO / GITHUB_REF / SUBDIR va quyen truy cap repo (phai la public)." >&2
        exit 1
    fi
done

echo ">> [3/5] Cai dat script chinh vao /usr/local/bin ..."
install -o root -g root -m 755 "${TMP_DIR}/disk-health-monitor.sh" /usr/local/bin/disk-health-monitor.sh

echo ">> [4/5] Cai dat systemd units vao /etc/systemd/system ..."
for unit in "${UNIT_FILES[@]}"; do
    install -o root -g root -m 644 "${TMP_DIR}/${unit}" "/etc/systemd/system/${unit}"
done

systemctl daemon-reload

echo ">> [5/5] Bat cac timer..."
systemctl enable --now disk-health-check.timer
systemctl enable --now disk-health-report.timer
systemctl enable --now disk-selftest-short.timer
systemctl enable --now disk-selftest-long.timer

echo
echo "=================================================================="
echo " Cai dat hoan tat!"
echo "=================================================================="
echo
echo "Cac timer dang hoat dong:"
systemctl list-timers 'disk-*' --no-pager 2>/dev/null || true
echo
echo "Kiem tra thu ngay:"
echo "  /usr/local/bin/disk-health-monitor.sh check"
echo
echo "QUAN TRONG: dam bao trong Datacenter -> Notifications da co it nhat"
echo "mot target/matcher khop type=system-mail (va root@pam co email hop le)."
echo "Xem huong dan trong README.md cua repo neu chua cau hinh."
echo
