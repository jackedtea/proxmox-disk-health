# Disk Health Monitor cho Proxmox VE

Giam sat SMART cua o dia SATA/NVMe, gui canh bao ngay khi phat hien loi va
gui bao cao day du moi tuan — thong qua he thong Notification cua Proxmox VE.

## Vi sao dung sendmail thay vi goi API notification truc tiep?

Tinh den hien tai, Proxmox VE **chua co API cong khai de gui mot notification
tuy y**. Cach duoc chinh doi Proxmox xac nhan la: gui mail cuc bo toi user
`root` bang lenh `sendmail`. Mail nay se duoc he thong tu dong bat (system
mail forwarding) va dua vao notification stack voi loai (type) la
`system-mail`, roi duoc dinh tuyen (route) toi cac target ban da cau hinh
trong Datacenter -> Notifications (email, Gotify, webhook, ...) theo cac
matcher hien co.

## Cai dat tu dong tu GitHub (khuyen nghi)

Sau khi push toan bo cac file trong thu muc nay len GitHub (repo cong khai
hoac private co the truy cap raw file), tren tung node Proxmox chi can chay
**1 lenh**:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/jackedtea/proxmox-disk-health/main/install.sh)" \
    GITHUB_REPO="jackedtea/proxmox-disk-health"
```

Hoac chi dinh truoc bang bien moi truong (khuyen nghi neu file khong nam o
root cua repo, hoac muon ghim theo tag/commit thay vi branch `main`):

```bash
GITHUB_REPO="jackedtea/proxmox-disk-health" GITHUB_REF="main" SUBDIR="" \
    sudo -E bash -c "$(curl -fsSL https://raw.githubusercontent.com/jackedtea/proxmox-disk-health/main/install.sh)"
```

| Bien | Y nghia | Vi du |
|---|---|---|
| `GITHUB_REPO` | `user/repo` tren GitHub | `anhvan/disk-health-monitor` |
| `GITHUB_REF` | branch, tag hoac commit hash | `main`, `v1.0.0` |
| `SUBDIR` | thu muc con chua cac file neu khong o root repo | `disk-health-monitor` |

Script `install.sh` se tu dong:
1. Cai `smartmontools` neu chua co
2. Tai tat ca file can thiet tu GitHub (raw.githubusercontent.com)
3. Copy script chinh vao `/usr/local/bin/`
4. Copy 8 file service/timer vao `/etc/systemd/system/`
5. `systemctl daemon-reload` va bat (`enable --now`) ca 4 timer

> **Luu y bao mat:** lenh tren tai va chay script bang quyen root truc tiep
> tu Internet (`curl | bash`). Chi thuc hien voi repo cua chinh ban / da tin
> tuong, va nen ghim `GITHUB_REF` vao mot **tag/commit cu the** thay vi
> `main` de tranh truong hop code thay doi ngoai y muon giua cac lan chay
> tren nhieu node. Neu muon can trong hon, tai `install.sh` ve truoc, doc
> qua noi dung, roi moi chay `sudo bash install.sh`.

### Chay lai / cap nhat phien ban moi

Chi can chay lai dung 1 lenh cai dat o tren — script se ghi de file cu bang
ban moi tai ve va khoi dong lai daemon-reload (khong can go cai dat truoc).

---

## Cai dat thu cong (khong dung GitHub)

```bash
# 1. Cai smartmontools neu chua co
apt update && apt install -y smartmontools

# 2. Copy script chinh
cp disk-health-monitor.sh /usr/local/bin/disk-health-monitor.sh
chmod +x /usr/local/bin/disk-health-monitor.sh

# 3. Copy cac unit systemd
cp disk-health-check.service   /etc/systemd/system/
cp disk-health-check.timer     /etc/systemd/system/
cp disk-health-report.service  /etc/systemd/system/
cp disk-health-report.timer    /etc/systemd/system/
cp disk-selftest-short.service /etc/systemd/system/
cp disk-selftest-short.timer   /etc/systemd/system/
cp disk-selftest-long.service  /etc/systemd/system/
cp disk-selftest-long.timer    /etc/systemd/system/

# 4. Nap lai systemd va bat cac timer
systemctl daemon-reload
systemctl enable --now disk-health-check.timer
systemctl enable --now disk-health-report.timer
systemctl enable --now disk-selftest-short.timer
systemctl enable --now disk-selftest-long.timer
```

## Kiem tra dam bao mail toi root duoc route dung

```bash
# Dam bao root@pam co email hop le (neu chua co)
pveum user modify root@pam -email your-email@example.com

# Kiem tra da co it nhat 1 target/matcher trong Datacenter -> Notifications
# (hoac qua CLI):
pvesh get /cluster/notifications/matchers
pvesh get /cluster/notifications/endpoints/sendmail
```

Neu chua co target nao, tao nhanh mot target sendmail mac dinh:

```bash
pvesh create /cluster/notifications/endpoints/sendmail \
  --name disk-health-mail \
  --mailto-user root@pam

pvesh create /cluster/notifications/matchers \
  --name disk-health-matcher \
  --target disk-health-mail \
  --match-field type=system-mail
```

## Chay thu ngay lap tuc

```bash
/usr/local/bin/disk-health-monitor.sh check       # kiem tra + canh bao neu co loi
/usr/local/bin/disk-health-monitor.sh report      # gui bao cao day du ngay lap tuc
/usr/local/bin/disk-health-monitor.sh test-short  # kich hoat SMART short self-test ngay
/usr/local/bin/disk-health-monitor.sh test-long   # kich hoat SMART long self-test ngay

# Xem log
journalctl -t disk-health-monitor -n 50

# Xem bao cao gan nhat da luu
cat /var/lib/disk-health-monitor/last_report.txt

# Xem tien do / ket qua self-test truc tiep tren 1 o dia
smartctl -l selftest -d sat  /dev/sda    # SATA
smartctl -l selftest -d nvme /dev/nvme0  # NVMe
```

## SMART self-test (short / long)

- `test-short`: kich hoat **short self-test** (thuong ~2 phut, kiem tra co ban dien tu +
  co gioi han vung dia). Duoc lap lich chay **hang tuan vao Chu Nhat luc 02:00**.
- `test-long`: kich hoat **long/extended self-test** (quet toan bo be mat dia, co the mat
  vai gio tuy dung luong). Duoc lap lich chay **hang thang vao ngay 1 luc 03:00**.
- Script chi **kich hoat** test roi thoat ngay (khong doi test chay xong), va gui 1 mail
  xac nhan da kich hoat thanh cong hay khong tren tung o dia.
- **Ket qua** cua lan self-test gan nhat se duoc lan chay `check` dinh ky tiep theo (06:00
  hoac 18:00) tu dong doc tu SMART self-test log va canh bao ngay neu test bi that bai
  (vi du: "Completed: read failure", "Completed: unknown failure" ...).
- Neu o dia dung lon (vai TB tro len), long test co the chua xong truoc lan `check` gan
  nhat — khong sao, lan `check` ke tiep se bat duoc ket qua khi test da hoan tat.

## Tuy chinh nguong canh bao

Sua cac bien o dau file `/usr/local/bin/disk-health-monitor.sh`:

| Bien | Y nghia | Mac dinh |
|---|---|---|
| `TEMP_WARN` | Nhiet do canh bao (C) | 55 |
| `TEMP_CRIT` | Nhiet do nguy hiem (C) | 65 |
| `NVME_USED_WARN` | % Percentage Used canh bao cho NVMe | 85 |

## Lich chay mac dinh

- `disk-health-check.timer`: 06:00 va 18:00 moi ngay — chi gui mail
  khi phat hien van de MOI (bao gom ca ket qua self-test that bai), va gui
  lai mot lan khi da khoi phuc (khong spam lap lai loi cu).
- `disk-health-report.timer`: 08:00 Thu Hai hang tuan — gui bao cao
  day du tinh trang tat ca o dia du co loi hay khong.
- `disk-selftest-short.timer`: 02:00 Chu Nhat hang tuan — kich hoat
  SMART short self-test tren tat ca o dia.
- `disk-selftest-long.timer`: 03:00 ngay 1 hang thang — kich hoat
  SMART long (extended) self-test tren tat ca o dia.

  > Luu y: neu ngay 1 roi vao Chu Nhat, ca 2 test se cung kich hoat trong
  > cung 1 ngay (short 02:00, long 03:00) — khong xung dot vi smartctl se
  > tu huy short test dang cho (neu con) khi long test bat dau.

## Kiem tra cac attribute duoc theo doi

**SATA (qua smartctl -A -d sat):**
- SMART overall-health (PASSED/FAILED)
- `Reallocated_Sector_Ct` > 0
- `Current_Pending_Sector` > 0
- `Offline_Uncorrectable` > 0
- `Temperature_Celsius` vuot nguong

**NVMe (qua smartctl -A -d nvme):**
- SMART overall-health
- `Critical Warning` khac `0x00`
- `Media and Data Integrity Errors` > 0
- `Percentage Used` >= nguong
- `Temperature` vuot nguong
