#!/usr/bin/env bash
# Back up every small partition (persist, EFS/IMEI, modem, dsp, bluetooth,
# dtbo, vbmeta, boot, ABL/XBL ...) plus the GPT of every UFS LUN.
#
# Needs a ROOT adb shell on the phone: TWRP or LineageOS recovery booted with
# `fastboot boot <recovery>.img`, or rooted Android (Magisk).
# Run from Git Bash, WSL2 or Linux:   ./backup-partitions.sh
# Result: ./guacamole-backup-<date>/  -- keep it PRIVATE (contains IMEI/keys)
# and keep 2 copies off the phone. Partitions > 512 MiB (system, vendor,
# userdata...) are skipped; they can be restored from an OxygenOS OTA.
set -euo pipefail
MAX=$((512*1024*1024))
OUT="guacamole-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

adb wait-for-device
if [ "$(adb shell id -u | tr -d '\r')" = "0" ]; then
  SU=0
elif [ "$(adb shell "su -c 'id -u'" 2>/dev/null | tr -d '\r')" = "0" ]; then
  SU=1
else
  echo "Need a root adb shell (TWRP / Lineage recovery / Magisk)"; exit 1
fi
# run a command as root on the phone, output with CR stripped
r() { if [ "$SU" = 1 ]; then adb shell "su -c '$*'"; else adb shell "$*"; fi | tr -d '\r'; }
TMP=$(adb shell '[ -d /tmp ] && [ -w /tmp ] && echo /tmp || echo /data/local/tmp' | tr -d '\r')/gbak
r "rm -rf $TMP; mkdir -p $TMP"

BYNAME=$(adb shell 'ls -d /dev/block/bootdevice/by-name 2>/dev/null || ls -d /dev/block/by-name' | tr -d '\r')
r "ls -l $BYNAME" > "$OUT/by-name-listing.txt"

for p in $(r "ls $BYNAME"); do
  sz=$(r "blockdev --getsize64 $BYNAME/$p")
  if [ -z "$sz" ] || [ "$sz" -gt "$MAX" ]; then echo "skip $p ($sz bytes)"; continue; fi
  echo "dump $p ($sz bytes)"
  r "dd if=$BYNAME/$p of=$TMP/$p.img bs=1M 2>/dev/null"
  adb pull "$TMP/$p.img" "$OUT/$p.img" >/dev/null
  r "rm -f $TMP/$p.img"
done

# GPT headers (first 24 KiB / last 20 KiB on 4K-sector UFS) of each LUN
for lun in sda sdb sdc sdd sde sdf; do
  [ "$(r "[ -b /dev/block/$lun ] && echo y")" = y ] || continue
  sz=$(r "blockdev --getsize64 /dev/block/$lun")
  r "dd if=/dev/block/$lun of=$TMP/gpt-$lun-primary.bin bs=4096 count=6 2>/dev/null"
  r "dd if=/dev/block/$lun of=$TMP/gpt-$lun-backup.bin bs=4096 skip=$((sz/4096-5)) count=5 2>/dev/null"
  echo "$lun $sz" >> "$OUT/lun-sizes.txt"
done
adb pull "$TMP/." "$OUT/" >/dev/null
r "rm -rf $TMP"
( cd "$OUT" && sha256sum * > SHA256SUMS )
echo "Backup complete: $OUT  ($(du -sh "$OUT" | cut -f1))"
echo "Check that persist.img, modemst1.img, modemst2.img, fsg.img, fsc.img exist and are non-zero."
