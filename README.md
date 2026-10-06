# Disk Health Monitor for Proxmox VE

Monitors SMART data of SATA/NVMe disks, alerts as soon as a problem is found,
sends a full report after every SMART self-test and once a week — all through
the Proxmox VE notification system.

## Why sendmail instead of the notification API?

Proxmox VE currently **has no public API for sending an arbitrary
notification**. The approach confirmed by the Proxmox team is to send local
mail to `root` with `sendmail`. That mail is picked up by system mail
forwarding and fed into the notification stack with type `system-mail`, then
routed to whatever targets you configured under Datacenter -> Notifications
(email, Gotify, webhook, ...) according to your matchers.

## Install from GitHub (recommended)

Run on each Proxmox node, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jackedtea/proxmox-disk-health/main/install.sh)"
```

To install from a fork, a subdirectory, or a pinned tag/commit:

```bash
GITHUB_REPO="jackedtea/proxmox-disk-health" GITHUB_REF="v1.0.0" SUBDIR="" bash -c "$(curl -fsSL https://raw.githubusercontent.com/jackedtea/proxmox-disk-health/main/install.sh)"
```

| Variable | Meaning | Default |
|---|---|---|
| `GITHUB_REPO` | `user/repo` on GitHub | `jackedtea/proxmox-disk-health` |
| `GITHUB_REF` | branch, tag or commit hash | `main` |
| `SUBDIR` | subdirectory holding the files, if not the repo root | *(empty)* |

`install.sh` will:
1. Install `smartmontools` if missing
2. Download all files from GitHub (raw.githubusercontent.com)
3. Install the main script to `/usr/local/bin/`
4. Install the 8 service/timer units to `/etc/systemd/system/`
5. `systemctl daemon-reload`, then enable and (re)start all 4 timers

> **Security note:** this downloads and runs a script as root straight from
> the Internet. Only do this with a repo you own or trust, and prefer pinning
> `GITHUB_REF` to a **specific tag/commit** instead of `main` so every node
> runs the same code. To be more careful, download `install.sh` first, read
> it, then run `bash install.sh`.

### Re-running / updating

Just run the same install command again — files are overwritten with the new
version and the timers are restarted. No need to uninstall first.

---

## Manual install (without GitHub)

```bash
# 1. Install smartmontools if missing
apt update && apt install -y smartmontools

# 2. Install the main script
install -m 755 disk-health-monitor.sh /usr/local/bin/disk-health-monitor.sh

# 3. Install the systemd units
install -m 644 disk-health-*.service disk-health-*.timer \
    disk-selftest-*.service disk-selftest-*.timer /etc/systemd/system/

# 4. Reload systemd and enable the timers
systemctl daemon-reload
systemctl enable --now disk-health-check.timer disk-health-report.timer \
    disk-selftest-short.timer disk-selftest-long.timer
```

## Make sure mail to root is routed

```bash
# Make sure root@pam has a valid email address
pveum user modify root@pam -email your-email@example.com

# Check there is at least one target/matcher under Datacenter -> Notifications
pvesh get /cluster/notifications/matchers
pvesh get /cluster/notifications/endpoints/sendmail
```

If there are no targets yet, create a default sendmail target:

```bash
pvesh create /cluster/notifications/endpoints/sendmail \
  --name disk-health-mail \
  --mailto-user root@pam

pvesh create /cluster/notifications/matchers \
  --name disk-health-matcher \
  --target disk-health-mail \
  --match-field type=system-mail
```

## Run manually

```bash
/usr/local/bin/disk-health-monitor.sh check       # check and alert on new problems
/usr/local/bin/disk-health-monitor.sh report      # send a full report right now
/usr/local/bin/disk-health-monitor.sh test-short  # run a short self-test, then mail the report
/usr/local/bin/disk-health-monitor.sh test-long   # run a long self-test, then mail the report

# Or in the background through systemd (recommended for test-long)
systemctl start --no-block disk-selftest-long.service

# Logs
journalctl -t disk-health-monitor -n 50

# Last saved report
cat /var/lib/disk-health-monitor/last_report.txt

# Self-test progress / results on a single disk
smartctl -l selftest -d sat  /dev/sda    # SATA
smartctl -l selftest -d nvme /dev/nvme0  # NVMe
```

## SMART self-tests (short / long)

- `test-short` starts a **short self-test** (usually ~2 minutes) on every disk.
  Scheduled **weekly on Sunday at 02:00**.
- `test-long` starts a **long/extended self-test** (scans the whole surface,
  can take hours depending on capacity). Scheduled **monthly on the 1st at 03:00**.
- After starting the tests, the script **waits until they finish** (polling
  every 60 s) and then **immediately sends one mail** with each disk's
  self-test result plus the full health report. The subject tells you the
  outcome at a glance:
  - `SMART short self-test passed - all disks healthy`
  - `SMART short self-test done - disk problems detected`
  - `ALERT: SMART short self-test FAILED`
- If a test is still running after `SHORT_MAX_WAIT` / `LONG_MAX_WAIT`, or the
  node reboots mid-test, the regular `check` run picks up the result from the
  SMART self-test log later.
- Self-test runs are serialized with a lock, so if the 1st of the month is a
  Sunday the long test simply starts after the short one finishes.
- Tests that were aborted or interrupted (e.g. by a reboot) are not reported
  as disk failures.

## Tuning

Edit the variables at the top of `/usr/local/bin/disk-health-monitor.sh`:

| Variable | Meaning | Default |
|---|---|---|
| `TEMP_WARN` | Temperature warning threshold (C) | 55 |
| `TEMP_CRIT` | Temperature critical threshold (C) | 65 |
| `NVME_USED_WARN` | NVMe Percentage Used warning threshold (%) | 85 |
| `POLL_INTERVAL` | Seconds between self-test progress checks | 60 |
| `SHORT_MAX_WAIT` | Max seconds to wait for a short self-test | 3600 |
| `LONG_MAX_WAIT` | Max seconds to wait for a long self-test | 172800 |

## Default schedule

- `disk-health-check.timer`: 06:00 and 18:00 daily — mails only when a **new**
  problem appears (including a failed self-test), and once more on recovery
  (known problems are not re-sent).
- `disk-health-report.timer`: Monday 08:00 — full report of all disks,
  whether or not there are problems.
- `disk-selftest-short.timer`: Sunday 02:00 — SMART short self-test on all
  disks, report mailed when it finishes.
- `disk-selftest-long.timer`: 1st of the month 03:00 — SMART long self-test
  on all disks, report mailed when it finishes.

## Monitored attributes

Disks and their device types are discovered with `smartctl --scan`.

**SATA:**
- SMART overall health (PASSED/FAILED)
- `Reallocated_Sector_Ct` > 0
- `Current_Pending_Sector` > 0
- `Offline_Uncorrectable` > 0
- `Temperature_Celsius` (or `Airflow_Temperature_Cel`) above threshold
- Result of the most recent self-test

**NVMe:**
- SMART overall health
- `Critical Warning` other than `0x00`
- `Media and Data Integrity Errors` > 0
- `Percentage Used` >= threshold
- `Temperature` above threshold
- Result of the most recent self-test
