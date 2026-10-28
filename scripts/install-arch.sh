#!/usr/bin/env bash
# Install Arch Linux ARM on the OnePlus 7 Pro from a Linux PC or WSL2, with the
# phone in U-Boot "USB mass storage" mode (see README, steps 4 and 5).
#
#   sudo bash scripts/install-arch.sh [--gui | --headless]
#        [--disk /dev/sdX]      # default: finds the phone's disk itself and asks
#        [--partition]          # first split userdata into userdata + esp + linux1
#                               # (DESTROYS ANDROID USER DATA; once only)
#        [--kernel build/guacamole-kernel-<rel>.tar.gz]   # default: newest in build/
#        [--firmware build/guacamole-firmware.tar.gz]     # default: that file
#
# It writes the Arch Linux ARM rootfs, our kernel, the DisplayPort device tree
# and a systemd-boot entry, turns on the USB network gadget (SSH at 10.66.0.1)
# and copies this kit plus the firmware to /home/alarm/guacamole-kit, so the
# rest runs on the phone:  bash ~/guacamole-kit/scripts/setup-arch.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$HERE/.." && pwd)
die() { echo "ERROR: $*" >&2; exit 1; }
DISK= MODE=gui PART=0 KPKG= FWTAR=
while [ $# -gt 0 ]; do case "$1" in
  --disk) DISK=$2; shift 2;; --gui) MODE=gui; shift;; --headless) MODE=headless; shift;;
  --partition) PART=1; shift;; --kernel) KPKG=$2; shift 2;; --firmware) FWTAR=$2; shift 2;;
  *) die "unknown arg $1 (see the top of this script)";; esac; done
[ "$(id -u)" = 0 ] || die "run with sudo"
for t in curl md5sum lsblk blkid; do command -v $t >/dev/null || die "missing $t"; done

# The phone's disk (UFS LUN0 in U-Boot mass-storage mode): 4096-byte sectors,
# a 'persist' partition, lsblk shows about 234G (256 GB model; 251.5 GB) or about 117G (128 GB model)
is_phone() {
  [ "$(lsblk -dno LOG-SEC "$1" 2>/dev/null | tr -d ' ')" = 4096 ] &&
    lsblk -lno PARTLABEL "$1" 2>/dev/null | grep -qx persist
}
describe() { lsblk -dno SIZE,MODEL "$1" | sed 's/  */ /g; s/^ //; s/ *$//'; }
if [ -z "$DISK" ]; then
  types="disk"; [ "${GUAC_ALLOW_LOOP:-0}" = 1 ] && types="disk loop"   # loop: for tests only
  found=()
  while read -r name type; do
    case " $types " in *" $type "*) is_phone "$name" && found+=("$name") ;; esac
  done < <(lsblk -dnpo NAME,TYPE)
  case ${#found[@]} in
    0) die "no phone disk found. Is the phone in U-Boot 'USB mass storage' mode (and attached to WSL with wsl-attach-phone.ps1)? Check with: lsblk -d -o NAME,SIZE,LOG-SEC,MODEL" ;;
    1) DISK=${found[0]} ;;
    *) die "more than one possible phone disk (${found[*]}); pick one with --disk" ;;
  esac
  echo "Found the phone's disk: $DISK ($(describe "$DISK"), 4096-byte sectors, has 'persist')"
  read -r -p "Install to $DISK? [y/N] " a; [ "$a" = y ] || die "aborted"
else
  [ -b "$DISK" ] || die "$DISK is not a disk"
  is_phone "$DISK" || die "$DISK is not the phone's disk (needs 4096-byte sectors and a 'persist' partition). Leave out --disk to find it automatically"
  echo "Phone disk: $DISK ($(describe "$DISK"))"
fi

KPKG=${KPKG:-$(ls -t "$PWD"/build/guacamole-kernel-*.tar.gz "$KIT"/build/guacamole-kernel-*.tar.gz 2>/dev/null | head -1 || true)}
[ -f "$KPKG" ] || die "no kernel package: run scripts/build-kernel.sh first, or pass --kernel"
FWTAR=${FWTAR:-$(ls "$PWD"/build/guacamole-firmware.tar.gz "$KIT"/build/guacamole-firmware.tar.gz 2>/dev/null | head -1 || true)}
[ -f "$FWTAR" ] || die "no firmware: run scripts/build-firmware.sh first, or pass --firmware"
DTB="$KIT/images/sm8150-oneplus-guacamole-dp.dtb"
[ -f "$DTB" ] || die "no $DTB: run scripts/build-uboot.sh first"

if [ "$PART" = 1 ]; then
  echo "== partitioning (userdata 4 GiB placeholder + 1 GiB ESP + linux1 = the rest)"
  bash "$HERE/partition-ufs.sh" "$DISK"
fi
part() { lsblk -lnpo NAME,PARTLABEL "$DISK" | awk -v l="$1" '$2 == l {print $1}'; }
ESP=$(part esp); ROOT=$(part linux1)
[ -b "$ESP" ] && [ -b "$ROOT" ] || die "no esp/linux1 partitions on $DISK (add --partition the first time)"
echo "ESP $ESP, root $ROOT, kernel $(basename "$KPKG"), mode $MODE"

echo "== Arch Linux ARM rootfs"
mkdir -p "$KIT/build"; cd "$KIT/build"
URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
[ -f ArchLinuxARM-aarch64-latest.tar.gz ] || curl -fL --progress-bar -o ArchLinuxARM-aarch64-latest.tar.gz "$URL"
curl -fsL -o ArchLinuxARM-aarch64-latest.tar.gz.md5 "$URL.md5"
md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5 || die "rootfs checksum mismatch: delete build/ArchLinuxARM-aarch64-latest.tar.gz and retry"

bash "$HERE/install-distro.sh" --root "$ROOT" --esp "$ESP" \
  --rootfs "$KIT/build/ArchLinuxARM-aarch64-latest.tar.gz" --kernel "$KPKG" \
  --id arch --title "Arch Linux ARM" --usbnet --dtb "$DTB"

echo "== kit + firmware -> /home/alarm/guacamole-kit"
M=$(mktemp -d); trap 'umount "$M" 2>/dev/null; rmdir "$M"' EXIT
mount "$ROOT" "$M"
G="$M/home/alarm/guacamole-kit"
rm -rf "$G"; mkdir -p "$G"
cp -r "$KIT/scripts" "$KIT/sensors" "$KIT/guacamole-tools" "$G/"
cp "$FWTAR" "$G/guacamole-firmware.tar.gz"
echo "MODE=$MODE" > "$G/setup.conf"
chown -R 1000:1000 "$G"            # alarm
sync
echo
echo "Done. Next:"
echo "  1. Detach the disk (Windows: scripts\\wsl-attach-phone.ps1 -Detach), reboot the phone."
echo "  2. On the PC, give the phone internet through SSH (password alarm):"
echo "       ssh -R 1080 alarm@10.66.0.1"
echo "  3. In that session:  su   (password root), then"
echo "       bash /home/alarm/guacamole-kit/scripts/setup-arch.sh"
echo "     It installs everything for the '$MODE' setup and asks you to reboot."
