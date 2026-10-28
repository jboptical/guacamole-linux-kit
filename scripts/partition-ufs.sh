#!/usr/bin/env bash
# Re-carve the OnePlus 7 Pro "userdata" area (UFS LUN0) into:
#   userdata (small placeholder, keeps ABL/fastboot happy)
#   esp      (FAT32 EFI System Partition shared by every distro)
#   linux1..N (ext4 roots, GPT type "Linux ARM64 root")
# Everything BEFORE userdata (persist, ssd, misc, ...) is left untouched.
#
# Run on a Linux PC (or WSL2 with usbipd) while the phone is in
# U-Boot "Enable USB mass storage" mode.  THIS DESTROYS ALL ANDROID USER DATA.
#
#   sudo ./partition-ufs.sh /dev/sdX [root sizes...]
#   e.g. sudo ./partition-ufs.sh /dev/sdb 64G 64G      -> linux1=64G linux2=64G linux3=rest
#   Env: USERDATA_SIZE (default 4G), ESP_SIZE (default 1G), DRY_RUN=1
set -euo pipefail
DEV="${1:?usage: $0 /dev/sdX [size ...]}"; shift || true
SIZES=("$@")
USERDATA_SIZE="${USERDATA_SIZE:-4G}"
ESP_SIZE="${ESP_SIZE:-1G}"
ARM64_ROOT=B921B045-1DF0-41C3-AF44-4C6F280D3FAE
die() { echo "ERROR: $*" >&2; exit 1; }
for t in sgdisk blockdev mkfs.vfat mkfs.ext4 partprobe; do command -v $t >/dev/null || die "missing $t (apt install gdisk dosfstools e2fsprogs parted)"; done
[ -b "$DEV" ] || die "$DEV is not a block device"

# ---- safety checks: is this really guacamole UFS LUN0? -------------------
SS=$(blockdev --getss "$DEV")
BYTES=$(blockdev --getsize64 "$DEV")
[ "$SS" = 4096 ] || die "logical sector size is $SS, expected 4096 (UFS). Wrong disk?"
# 256 GB phones: LUN0 is 251.5 GB (lsblk: 234G); 128 GB phones: roughly 125 GB
[ "$BYTES" -gt $((100*1000**3)) ] && [ "$BYTES" -lt $((260*1000**3)) ] || die "size $BYTES is not a OnePlus 7 Pro (128 or 256 GB) LUN0. Wrong disk?"
TABLE=$(sgdisk -p "$DEV") || die "no GPT on $DEV"
echo "$TABLE" | grep -qw persist || die "no 'persist' partition: this is not LUN0 of the OnePlus"
N_UD=$(echo "$TABLE" | awk '$1 ~ /^[0-9]+$/ && $NF=="userdata"{print $1}')
[ -n "$N_UD" ] || die "no 'userdata' partition found (already re-partitioned? use sgdisk manually)"
LAST=$(echo "$TABLE" | awk '$1 ~ /^[0-9]+$/{ if ($3+0 > m) { m=$3+0; n=$1 } } END{print n}')
[ "$LAST" = "$N_UD" ] || die "userdata (#$N_UD) is not the last partition (#$LAST); refusing"
UD_START=$(sgdisk -i "$N_UD" "$DEV" | awk '/First sector/{print $3}')
UD_TYPE=$(sgdisk -i "$N_UD" "$DEV" | awk '/Partition GUID code/{print $4}')
UD_ATTR=$(sgdisk -i "$N_UD" "$DEV" | awk '/Attribute flags/{print $3}')
MAXNUM=$(echo "$TABLE" | awk '$1 ~ /^[0-9]+$/{ if ($1+0 > m) m=$1+0 } END{print m}')

echo "$TABLE"
echo
echo "Plan for $DEV (userdata is #$N_UD, starts at sector $UD_START):"
echo "  #$N_UD userdata  $USERDATA_SIZE  (type $UD_TYPE, kept as placeholder)"
echo "  #$((MAXNUM+1)) esp       $ESP_SIZE  FAT32"
i=1; n=$((MAXNUM+2))
for s in "${SIZES[@]}"; do echo "  #$n linux$i    $s  ext4"; i=$((i+1)); n=$((n+1)); done
echo "  #$n linux$i    (rest of disk)  ext4"
[ "${DRY_RUN:-0}" = 1 ] && { echo "DRY_RUN=1, nothing written"; exit 0; }
read -r -p "Type ERASE-USERDATA to continue: " ans
[ "$ans" = ERASE-USERDATA ] || die "aborted"

BK="gpt-lun0-backup-$(date +%Y%m%d-%H%M%S).sgdisk"
sgdisk --backup="$BK" "$DEV"; echo "GPT backup saved to $BK (restore: sgdisk --load-backup=$BK $DEV)"

sgdisk -d "$N_UD" "$DEV"
sgdisk -n "$N_UD:$UD_START:+$USERDATA_SIZE" -t "$N_UD:$UD_TYPE" -c "$N_UD:userdata" "$DEV"
[ -n "$UD_ATTR" ] && [ "$UD_ATTR" != 0000000000000000 ] && sgdisk -A "$N_UD:=:$UD_ATTR" "$DEV" || true
NUM=$((MAXNUM+1))
sgdisk -n "$NUM:0:+$ESP_SIZE" -t "$NUM:EF00" -c "$NUM:esp" "$DEV"; ESP_NUM=$NUM
ROOTS=(); i=1
for s in "${SIZES[@]}"; do
  NUM=$((NUM+1)); sgdisk -n "$NUM:0:+$s" -t "$NUM:$ARM64_ROOT" -c "$NUM:linux$i" "$DEV"; ROOTS+=("$NUM:linux$i"); i=$((i+1))
done
NUM=$((NUM+1)); sgdisk -n "$NUM:0:0" -t "$NUM:$ARM64_ROOT" -c "$NUM:linux$i" "$DEV"; ROOTS+=("$NUM:linux$i")
partprobe "$DEV" || true; udevadm settle 2>/dev/null || sleep 3

part() { case "$DEV" in *[0-9]) echo "${DEV}p$1";; *) echo "${DEV}$1";; esac; }
mkfs.vfat -F 32 -S 4096 -n ESP "$(part $ESP_NUM)"
for r in "${ROOTS[@]}"; do mkfs.ext4 -q -F -b 4096 -L "${r#*:}" "$(part ${r%%:*})"; done
sgdisk -p "$DEV"
echo
echo "PARTUUIDs (use these in loader entries: root=PARTUUID=...):"
for r in "${ROOTS[@]}"; do echo "  ${r#*:}  $(sgdisk -i ${r%%:*} "$DEV" | awk '/unique GUID/{print tolower($4)}')"; done
echo "  esp     $(sgdisk -i $ESP_NUM "$DEV" | awk '/unique GUID/{print tolower($4)}')"
