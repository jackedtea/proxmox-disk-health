#!/usr/bin/env bash
#
# disk-health-monitor.sh
# Giam sat suc khoe o dia SATA/NVMe cho Proxmox VE.
# Gui canh bao / bao cao qua "sendmail" toi root -> duoc Proxmox feed vao
# notification stack voi type "system-mail" va route theo matcher da cau hinh
# (Datacenter -> Notifications).
#
# Cach dung:
#   disk-health-monitor.sh check       # kiem tra suc khoe + doc log self-test,
#                                       # chi gui mail khi co van de / khi khoi phuc
#   disk-health-monitor.sh report      # gui bao cao day du (dung cho lich hang tuan)
#   disk-health-monitor.sh test-short  # kich hoat SMART short self-test tren tat ca o dia
#   disk-health-monitor.sh test-long   # kich hoat SMART long (extended) self-test

set -uo pipefail

# ================= CAU HINH =================
MAIL_TO="root"                 # Proxmox forward mail cua root vao notification stack
HOSTNAME_STR="$(hostname -f 2>/dev/null || hostname)"
TEMP_WARN=55                   # Nguong nhiet do canh bao (C)
TEMP_CRIT=65                   # Nguong nhiet do nguy hiem (C)
NVME_USED_WARN=85              # % Percentage Used canh bao cho NVMe
STATE_DIR="/var/lib/disk-health-monitor"
LOG_TAG="disk-health-monitor"
# ==============================================

mkdir -p "$STATE_DIR"
MODE="${1:-check}"   # check | report | test-short | test-long

command -v smartctl >/dev/null 2>&1 || {
    echo "Loi: khong tim thay smartctl. Cai dat bang: apt install smartmontools" >&2
    exit 1
}
command -v sendmail >/dev/null 2>&1 || {
    echo "Loi: khong tim thay sendmail (can co MTA nhu postfix/exim de Proxmox forward mail)." >&2
    exit 1
}

declare -a ISSUES=()
declare -a REPORT_LINES=()
declare -a TEST_LINES=()

log() { logger -t "$LOG_TAG" "$*"; }

send_mail() {
    local subject="$1" body="$2"
    {
        echo "To: ${MAIL_TO}"
        echo "From: ${LOG_TAG}@${HOSTNAME_STR}"
        echo "Subject: ${subject}"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo
        echo -e "$body"
    } | sendmail -t
}

get_disks() {
    # In ra "device|type", vi du: /dev/sda|sat  hoac /dev/nvme0|nvme
    smartctl --scan 2>/dev/null | awk '{print $1"|"$3}'
}

# ---------- Kich hoat self-test (mode = short|long) ----------
trigger_selftest() {
    local test_mode="$1"   # short | long
    while IFS='|' read -r dev type; do
        [[ -z "$dev" ]] && continue
        local dtype="sat"
        [[ "$type" == "nvme" ]] && dtype="nvme"
        local out
        out="$(smartctl -t "$test_mode" -d "$dtype" "$dev" 2>&1)"
        if echo "$out" | grep -qi "please wait\|test will complete after\|has begun"; then
            TEST_LINES+=("[$dev] Da kich hoat SMART ${test_mode} self-test thanh cong")
            log "Kich hoat ${test_mode} self-test tren $dev: OK"
        else
            TEST_LINES+=("[$dev] LOI khi kich hoat ${test_mode} self-test: $(echo "$out" | tail -1)")
            log "Kich hoat ${test_mode} self-test tren $dev: THAT BAI"
        fi
    done < <(get_disks)
}

# ---------- Doc ket qua self-test gan nhat (dung trong mode "check") ----------
selftest_status_sata() {
    local dev="$1"
    smartctl -l selftest -d sat "$dev" 2>/dev/null | \
        awk '/^# 1 /{ $0=$0; print }' | head -1
}

selftest_status_nvme() {
    local dev="$1"
    smartctl -l selftest -d nvme "$dev" 2>/dev/null | \
        awk '/^0 /{ print; exit }'
}

check_selftest_log() {
    local dev="$1" type="$2" line
    if [[ "$type" == "nvme" ]]; then
        line="$(selftest_status_nvme "$dev")"
        [[ -z "$line" ]] && return
        if ! echo "$line" | grep -qi "Completed without error\|Success"; then
            ISSUES+=("[$dev] SMART self-test gan nhat KHONG thanh cong: $line")
        fi
    else
        line="$(selftest_status_sata "$dev")"
        [[ -z "$line" ]] && return
        if ! echo "$line" | grep -qi "Completed without error"; then
            ISSUES+=("[$dev] SMART self-test gan nhat KHONG thanh cong: $line")
        fi
    fi
}

check_sata() {
    local dev="$1" out health realloc pending uncorr temp status detail
    out="$(smartctl -H -A -d sat "$dev" 2>/dev/null)"
    [[ -z "$out" ]] && out="$(smartctl -H -A "$dev" 2>/dev/null)"

    health="$(echo "$out" | grep -i "overall-health" | awk -F: '{print $2}' | xargs)"
    realloc="$(echo "$out" | awk '/Reallocated_Sector_Ct/{print $10}')"
    pending="$(echo "$out" | awk '/Current_Pending_Sector/{print $10}')"
    uncorr="$(echo "$out" | awk '/Offline_Uncorrectable/{print $10}')"
    temp="$(echo "$out" | awk '/Temperature_Celsius/{print $10}' | head -1)"

    status="OK"
    detail="Health=${health:-N/A} Realloc=${realloc:-0} Pending=${pending:-0} Uncorr=${uncorr:-0} Temp=${temp:-N/A}C"

    if [[ "${health,,}" == *"failed"* ]]; then
        status="CRITICAL"; ISSUES+=("[$dev] SMART overall health: FAILED")
    fi
    if [[ -n "${realloc:-}" ]] && [[ "$realloc" =~ ^[0-9]+$ ]] && (( realloc > 0 )); then
        status="WARNING"; ISSUES+=("[$dev] Reallocated_Sector_Ct = $realloc (>0)")
    fi
    if [[ -n "${pending:-}" ]] && [[ "$pending" =~ ^[0-9]+$ ]] && (( pending > 0 )); then
        status="WARNING"; ISSUES+=("[$dev] Current_Pending_Sector = $pending (>0)")
    fi
    if [[ -n "${uncorr:-}" ]] && [[ "$uncorr" =~ ^[0-9]+$ ]] && (( uncorr > 0 )); then
        status="CRITICAL"; ISSUES+=("[$dev] Offline_Uncorrectable = $uncorr (>0)")
    fi
    if [[ -n "${temp:-}" ]] && [[ "$temp" =~ ^[0-9]+$ ]]; then
        if (( temp >= TEMP_CRIT )); then
            status="CRITICAL"; ISSUES+=("[$dev] Nhiet do ${temp}C >= nguong nguy hiem ${TEMP_CRIT}C")
        elif (( temp >= TEMP_WARN )); then
            [[ "$status" == "OK" ]] && status="WARNING"
            ISSUES+=("[$dev] Nhiet do ${temp}C >= nguong canh bao ${TEMP_WARN}C")
        fi
    fi

    if [[ "$MODE" == "check" ]]; then
        check_selftest_log "$dev" "sat"
    fi

    REPORT_LINES+=("$(printf '%-16s %-8s %s' "$dev" "$status" "$detail")")
}

check_nvme() {
    local dev="$1" out health crit used media temp status detail
    out="$(smartctl -H -A -d nvme "$dev" 2>/dev/null)"

    health="$(echo "$out" | grep -i "overall-health" | awk -F: '{print $2}' | xargs)"
    crit="$(echo "$out" | awk -F: '/Critical Warning/{gsub(/ /,"",$2); print $2}')"
    used="$(echo "$out" | awk -F: '/Percentage Used/{gsub(/[^0-9]/,"",$2); print $2}')"
    media="$(echo "$out" | awk -F: '/Media and Data Integrity Errors/{gsub(/[^0-9]/,"",$2); print $2}')"
    temp="$(echo "$out" | awk -F: '/^Temperature:/{gsub(/[^0-9]/,"",$2); print $2}')"

    status="OK"
    detail="Health=${health:-N/A} CritWarn=${crit:-0x00} Used=${used:-0}% MediaErr=${media:-0} Temp=${temp:-N/A}C"

    if [[ "${health,,}" == *"failed"* ]]; then
        status="CRITICAL"; ISSUES+=("[$dev] SMART overall health: FAILED")
    fi
    if [[ -n "${crit:-}" && "$crit" != "0x00" ]]; then
        status="CRITICAL"; ISSUES+=("[$dev] Critical Warning = $crit (khac 0x00)")
    fi
    if [[ -n "${media:-}" ]] && [[ "$media" =~ ^[0-9]+$ ]] && (( media > 0 )); then
        status="CRITICAL"; ISSUES+=("[$dev] Media and Data Integrity Errors = $media (>0)")
    fi
    if [[ -n "${used:-}" ]] && [[ "$used" =~ ^[0-9]+$ ]] && (( used >= NVME_USED_WARN )); then
        [[ "$status" == "OK" ]] && status="WARNING"
        ISSUES+=("[$dev] Percentage Used = ${used}% (>= ${NVME_USED_WARN}%)")
    fi
    if [[ -n "${temp:-}" ]] && [[ "$temp" =~ ^[0-9]+$ ]]; then
        if (( temp >= TEMP_CRIT )); then
            status="CRITICAL"; ISSUES+=("[$dev] Nhiet do ${temp}C >= nguong nguy hiem ${TEMP_CRIT}C")
        elif (( temp >= TEMP_WARN )); then
            [[ "$status" == "OK" ]] && status="WARNING"
            ISSUES+=("[$dev] Nhiet do ${temp}C >= nguong canh bao ${TEMP_WARN}C")
        fi
    fi

    if [[ "$MODE" == "check" ]]; then
        check_selftest_log "$dev" "nvme"
    fi

    REPORT_LINES+=("$(printf '%-16s %-8s %s' "$dev" "$status" "$detail")")
}

# ================= XU LY THEO MODE =================

if [[ "$MODE" == "test-short" || "$MODE" == "test-long" ]]; then
    test_type="${MODE#test-}"   # short | long
    trigger_selftest "$test_type"

    BODY="Da kich hoat SMART ${test_type} self-test tren cac o dia:\n\n$(printf '%s\n' "${TEST_LINES[@]}")\n\nKet qua se duoc kiem tra va bao cao trong lan 'check' dinh ky tiep theo (script doc SMART self-test log)."
    send_mail "[Proxmox][${HOSTNAME_STR}] Da kich hoat SMART ${test_type} self-test" "$BODY"
    log "Da kich hoat ${test_type} self-test cho tat ca o dia"
    exit 0
fi

while IFS='|' read -r dev type; do
    [[ -z "$dev" ]] && continue
    case "$type" in
        nvme) check_nvme "$dev" ;;
        *)    check_sata "$dev" ;;
    esac
done < <(get_disks)

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
{
    echo "Bao cao suc khoe o dia - ${HOSTNAME_STR}"
    echo "Thoi gian: ${TIMESTAMP}"
    echo "================================================"
    printf '%-16s %-8s %s\n' "THIET BI" "TRANG THAI" "CHI TIET"
    for line in "${REPORT_LINES[@]:-}"; do
        [[ -n "$line" ]] && echo "$line"
    done
} > "$STATE_DIR/last_report.txt"

if [[ "$MODE" == "report" ]]; then
    send_mail "[Proxmox][${HOSTNAME_STR}] Bao cao suc khoe o dia hang tuan" \
        "$(cat "$STATE_DIR/last_report.txt")"
    log "Da gui bao cao hang tuan"
    exit 0
fi

# MODE = check: chi gui mail khi co van de moi (bao gom ca ket qua self-test that bai),
# va gui thong bao khi da khoi phuc
LAST_HASH_FILE="$STATE_DIR/last_issue_hash"

if [[ ${#ISSUES[@]} -gt 0 ]]; then
    ISSUE_HASH="$(printf '%s\n' "${ISSUES[@]}" | sort | md5sum | awk '{print $1}')"
    LAST_HASH=""
    [[ -f "$LAST_HASH_FILE" ]] && LAST_HASH="$(cat "$LAST_HASH_FILE")"

    if [[ "$ISSUE_HASH" != "$LAST_HASH" ]]; then
        BODY="Phat hien van de tren cac o dia sau:\n\n$(printf '%s\n' "${ISSUES[@]}")\n\n---\n$(cat "$STATE_DIR/last_report.txt")"
        send_mail "[Proxmox][${HOSTNAME_STR}] CANH BAO: phat hien loi o dia" "$BODY"
        echo "$ISSUE_HASH" > "$LAST_HASH_FILE"
        log "Da gui canh bao loi o dia"
    else
        log "Van con loi cu, khong gui lai mail de tranh spam"
    fi
else
    if [[ -f "$LAST_HASH_FILE" ]]; then
        send_mail "[Proxmox][${HOSTNAME_STR}] Da khoi phuc: o dia hoat dong binh thuong" \
            "Tat ca o dia da tro ve trang thai binh thuong.\n\n$(cat "$STATE_DIR/last_report.txt")"
        rm -f "$LAST_HASH_FILE"
        log "Da gui thong bao khoi phuc"
    fi
    log "Khong phat hien van de"
fi
