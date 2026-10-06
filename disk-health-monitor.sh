#!/usr/bin/env bash
#
# disk-health-monitor.sh
# SMART health monitoring for SATA/NVMe disks on Proxmox VE.
# Alerts and reports are sent with "sendmail" to root; Proxmox feeds that mail
# into its notification stack as type "system-mail" and routes it according to
# the configured matchers (Datacenter -> Notifications).
#
# Usage:
#   disk-health-monitor.sh check       # health check + last self-test result;
#                                      # mails only on new issues / on recovery
#   disk-health-monitor.sh report      # always mail a full report (weekly)
#   disk-health-monitor.sh test-short  # run a SMART short self-test on all disks,
#                                      # wait for it to finish, then mail the report
#   disk-health-monitor.sh test-long   # same, with the long (extended) self-test

set -uo pipefail

# ================= CONFIG =================
MAIL_TO="root"                 # Proxmox forwards root's mail into the notification stack
TEMP_WARN=55                   # Temperature warning threshold (C)
TEMP_CRIT=65                   # Temperature critical threshold (C)
NVME_USED_WARN=85              # NVMe "Percentage Used" warning threshold (%)
POLL_INTERVAL=60               # Seconds between self-test progress checks
SHORT_MAX_WAIT=3600            # Stop waiting for a short self-test after 1h
LONG_MAX_WAIT=172800           # Stop waiting for a long self-test after 48h
STATE_DIR="/var/lib/disk-health-monitor"
LOG_TAG="disk-health-monitor"
# ==========================================

MODE="${1:-check}"
case "$MODE" in
    check|report|test-short|test-long) ;;
    *) echo "Usage: $0 {check|report|test-short|test-long}" >&2; exit 2 ;;
esac

command -v smartctl >/dev/null 2>&1 || {
    echo "Error: smartctl not found. Install it with: apt install smartmontools" >&2
    exit 1
}
command -v sendmail >/dev/null 2>&1 || {
    echo "Error: sendmail not found (an MTA such as postfix is required for Proxmox to forward mail)." >&2
    exit 1
}

HOST="$(hostname -f 2>/dev/null || hostname)"
HASH_FILE="$STATE_DIR/last_issue_hash"
REPORT_FILE="$STATE_DIR/last_report.txt"
mkdir -p "$STATE_DIR"

declare -a ISSUES=() REPORT_LINES=()
declare -A LAST_TEST=()        # device -> most recent self-test log entry
REPORT=""

log() { logger -t "$LOG_TAG" -- "$*"; }

send_mail() {
    local subject="$1" body="$2"
    printf 'To: %s\nFrom: %s@%s\nSubject: [Proxmox][%s] %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$MAIL_TO" "$LOG_TAG" "$HOST" "$HOST" "$subject" "$body" | sendmail -t
}

is_num() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Prints "device type" per line, e.g. "/dev/sda sat" or "/dev/nvme0 nvme".
get_disks() { smartctl --scan 2>/dev/null | awk '{print $1, $3}'; }

# Records an issue and escalates the caller's $status (never downgrades it).
raise() {   # raise LEVEL LABEL MESSAGE
    ISSUES+=("[$2] $3")
    if [[ "$1" == CRITICAL ]]; then status=CRITICAL
    elif [[ "$status" == OK ]]; then status=WARNING
    fi
}

# Most recent self-test log entry (SATA "# 1 ..." / NVMe " 0 ..."), spaces squeezed.
last_selftest() {
    awk '/^# *1 / || /^ *0 +[A-Za-z]/ { sub(/^#? *[01] +/, ""); gsub(/ +/, " "); print; exit }' <<<"$1"
}

# PASS | FAIL | SKIP (aborted/interrupted/running - not a disk fault) | NONE
selftest_verdict() {
    case "${1,,}" in
        "")                                        echo NONE ;;
        *"completed without error"*|*success*)     echo PASS ;;
        *progress*|*aborted*|*interrupted*)        echo SKIP ;;
        *)                                         echo FAIL ;;
    esac
}

selftest_running() {   # selftest_running DEVICE TYPE
    if [[ "$2" == nvme ]]; then
        # "Self-test status: Short self-test in progress (35% completed)" vs "No self-test in progress"
        smartctl -d nvme -l selftest "$1" 2>/dev/null | grep -i '^Self-test status:' | grep -vqi 'no self-test'
    else
        smartctl -d "$2" -c "$1" 2>/dev/null | grep -qi 'self-test routine in progress'
    fi
}

check_disk() {
    local dev="$1" type="$2" label="$1" status=OK out health detail temp last verdict
    [[ "$type" == *,* ]] && label="$dev ($type)"   # e.g. megaraid,N behind one /dev/bus/N

    # One smartctl call per disk: health + attributes + self-test log.
    out="$(smartctl -d "$type" -H -A -l selftest "$dev" 2>/dev/null)"

    health="$(awk -F': *' '/overall-health|SMART Health Status/ { print $2; exit }' <<<"$out")"
    [[ "${health,,}" == *failed* ]] && raise CRITICAL "$label" "SMART overall health: FAILED"

    if [[ "$type" == nvme ]]; then
        local crit used media
        read -r crit used media temp < <(awk -F: '
            function num(s) { gsub(/[^0-9]/, "", s); return s == "" ? "-" : s }
            BEGIN { c = u = m = t = "-" }
            /^Critical Warning:/                { c = $2; gsub(/ /, "", c) }
            /^Percentage Used:/                 { u = num($2) }
            /^Media and Data Integrity Errors:/ { m = num($2) }
            /^Temperature:/                     { t = num($2) }
            END { print c, u, m, t }' <<<"$out")

        [[ "$crit" != "-" && "$crit" != 0x00 ]] && raise CRITICAL "$label" "Critical Warning = $crit (not 0x00)"
        is_num "$media" && (( media > 0 )) && raise CRITICAL "$label" "Media and Data Integrity Errors = $media (>0)"
        is_num "$used" && (( used >= NVME_USED_WARN )) && raise WARNING "$label" "Percentage Used = ${used}% (>= ${NVME_USED_WARN}%)"
        detail="CritWarn=$crit Used=${used}% MediaErr=$media"
    else
        local realloc pending uncorr
        read -r realloc pending uncorr temp < <(awk '
            BEGIN { r = p = u = t = a = "-" }
            $2 == "Reallocated_Sector_Ct"   { r = $10 }
            $2 == "Current_Pending_Sector"  { p = $10 }
            $2 == "Offline_Uncorrectable"   { u = $10 }
            $2 == "Temperature_Celsius"     { t = $10 }
            $2 == "Airflow_Temperature_Cel" { a = $10 }
            END { if (t == "-") t = a; print r, p, u, t }' <<<"$out")

        is_num "$realloc" && (( realloc > 0 )) && raise WARNING  "$label" "Reallocated_Sector_Ct = $realloc (>0)"
        is_num "$pending" && (( pending > 0 )) && raise WARNING  "$label" "Current_Pending_Sector = $pending (>0)"
        is_num "$uncorr"  && (( uncorr > 0 ))  && raise CRITICAL "$label" "Offline_Uncorrectable = $uncorr (>0)"
        detail="Realloc=$realloc Pending=$pending Uncorr=$uncorr"
    fi

    if is_num "$temp"; then
        if (( temp >= TEMP_CRIT )); then
            raise CRITICAL "$label" "Temperature ${temp}C >= critical threshold ${TEMP_CRIT}C"
        elif (( temp >= TEMP_WARN )); then
            raise WARNING "$label" "Temperature ${temp}C >= warning threshold ${TEMP_WARN}C"
        fi
    fi

    last="$(last_selftest "$out")"
    verdict="$(selftest_verdict "$last")"
    LAST_TEST["$dev"]="$last"
    [[ "$verdict" == FAIL ]] && raise CRITICAL "$label" "Last SMART self-test failed: $last"

    is_num "$temp" && temp="${temp}C" || temp="N/A"
    REPORT_LINES+=("$(printf '%-16s %-9s Health=%s %s Temp=%s LastTest=%s' \
        "$label" "$status" "${health:-N/A}" "$detail" "$temp" "$verdict")")
}

# Checks every disk, builds $REPORT and saves it to $REPORT_FILE.
run_checks() {
    local dev type
    ISSUES=(); REPORT_LINES=(); LAST_TEST=()
    while read -r dev type; do
        [[ -n "$dev" ]] && check_disk "$dev" "$type"
    done < <(get_disks)

    REPORT="Disk health report - ${HOST}
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')
================================================================
$(printf '%-16s %-9s %s\n' DEVICE STATUS DETAILS)"
    (( ${#REPORT_LINES[@]} )) && REPORT+=$'\n'"$(printf '%s\n' "${REPORT_LINES[@]}")"
    (( ${#ISSUES[@]} ))       && REPORT+=$'\n\n'"Issues:"$'\n'"$(printf '  %s\n' "${ISSUES[@]}")"
    printf '%s\n' "$REPORT" > "$REPORT_FILE"
}

issue_hash() { printf '%s\n' "${ISSUES[@]}" | sort | md5sum | cut -d' ' -f1; }

# Remembers the current issue set so "check" doesn't re-send what was already mailed.
save_state() {
    if (( ${#ISSUES[@]} )); then issue_hash > "$HASH_FILE"; else rm -f "$HASH_FILE"; fi
}

# check: mail only when the issue set changes, and once more on recovery.
notify_changes() {
    if (( ${#ISSUES[@]} )); then
        if [[ "$(issue_hash)" == "$(cat "$HASH_FILE" 2>/dev/null)" ]]; then
            log "Known issues persist, not re-sending alert"
            return
        fi
        send_mail "ALERT: disk problems detected" "Problems detected on the following disks:

$(printf '%s\n' "${ISSUES[@]}")

---
${REPORT}"
        log "Sent disk problem alert"
    elif [[ -f "$HASH_FILE" ]]; then
        send_mail "Recovered: all disks healthy" "All disks are back to normal.

${REPORT}"
        log "Sent recovery notice"
    else
        log "No problems detected"
    fi
    save_state
}

# test-short / test-long: start the test, wait for it to finish, then mail the report.
run_selftest() {
    local kind="$1" max_wait=$SHORT_MAX_WAIT dev type out entry verdict subject
    local -a started=() pending=() still=() lines=()
    [[ "$kind" == long ]] && max_wait=$LONG_MAX_WAIT

    # Serialize self-test runs (e.g. short and long scheduled on the same day).
    exec 9>"$STATE_DIR/selftest.lock"
    flock 9

    while read -r dev type; do
        [[ -z "$dev" ]] && continue
        out="$(smartctl -d "$type" -t "$kind" "$dev" 2>&1)"
        if grep -qiE 'has begun|please wait|test will complete after' <<<"$out"; then
            started+=("$dev $type")
            log "Started $kind self-test on $dev"
        else
            lines+=("[$dev] FAILED TO START: $(tail -n1 <<<"$out")")
            log "Failed to start $kind self-test on $dev"
        fi
    done < <(get_disks)

    pending=("${started[@]}")
    local deadline=$(( SECONDS + max_wait ))
    while (( ${#pending[@]} )) && (( SECONDS < deadline )); do
        sleep "$POLL_INTERVAL"
        still=()
        for entry in "${pending[@]}"; do
            selftest_running $entry && still+=("$entry")
        done
        pending=("${still[@]}")
    done

    run_checks

    local failed=0
    for entry in "${started[@]}"; do
        dev="${entry% *}"
        if [[ " ${pending[*]} " == *" $entry "* ]]; then
            lines+=("[$dev] STILL RUNNING after $(( max_wait / 3600 ))h - result will be picked up by the next check")
            continue
        fi
        verdict="$(selftest_verdict "${LAST_TEST[$dev]:-}")"
        lines+=("[$dev] $verdict: ${LAST_TEST[$dev]:-no self-test log entry}")
        [[ "$verdict" == FAIL ]] && failed=1
    done

    if (( ! ${#started[@]} )); then
        subject="SMART $kind self-test could not be started on any disk"
    elif (( failed )); then
        subject="ALERT: SMART $kind self-test FAILED"
    elif (( ${#ISSUES[@]} )); then
        subject="SMART $kind self-test done - disk problems detected"
    else
        subject="SMART $kind self-test passed - all disks healthy"
    fi

    send_mail "$subject" "SMART $kind self-test results:

$(printf '%s\n' "${lines[@]}")

---
${REPORT}"
    save_state
    log "Sent $kind self-test report"
}

case "$MODE" in
    test-short|test-long)
        run_selftest "${MODE#test-}"
        ;;
    report)
        run_checks
        send_mail "Weekly disk health report" "$REPORT"
        log "Sent weekly report"
        ;;
    check)
        run_checks
        notify_changes
        ;;
esac
