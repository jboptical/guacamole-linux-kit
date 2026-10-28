#!/usr/bin/env bash
# Install a distro rootfs onto one of the linuxN partitions and register it
# with systemd-boot on the shared ESP.  Run on a Linux PC while the phone is
# in U-Boot "USB mass storage" mode (or from another Linux already on the phone).
#
#   sudo ./install-distro.sh --root /dev/sdX15 --esp /dev/sdX14 \
#        --rootfs ArchLinuxARM-aarch64-latest.tar.gz \
#        --kernel build/guacamole-kernel-6.17.0-sm8150.tar.gz \
#        --id arch --title "Arch Linux ARM" \
#        [--firmware ./guacamole-firmware]   # tree copied into /usr/lib/firmware
#        [--usbnet]                          # USB network gadget 10.66.0.1 for SSH
#        [--sdboot systemd-bootaa64.efi]     # if the rootfs doesn't ship one
#        [--cmdline "extra args"]
#        [--dtb images/sm8150-oneplus-guacamole-dp.dtb]  # DT for Linux (DisplayPort);
#                                            # copied to ESP/dtbs/ and used by the entry
#
# --rootfs may be a .tar(.gz/.xz/.zst) rootfs tarball or an already-populated directory.
set -euo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }
ROOT= ESP= ROOTFS= KERNEL= ID= TITLE= FW= USBNET=0 SDBOOT= EXTRA= DTB=
while [ $# -gt 0 ]; do case "$1" in
  --root) ROOT=$2; shift 2;; --esp) ESP=$2; shift 2;; --rootfs) ROOTFS=$2; shift 2;;
  --kernel) KERNEL=$2; shift 2;; --id) ID=$2; shift 2;; --title) TITLE=$2; shift 2;;
  --firmware) FW=$2; shift 2;; --usbnet) USBNET=1; shift;; --sdboot) SDBOOT=$2; shift 2;;
  --cmdline) EXTRA=$2; shift 2;; --dtb) DTB=$2; shift 2;; *) die "unknown arg $1";; esac; done
[ -z "$DTB" ] || [ -f "$DTB" ] || die "no DTB $DTB"
for v in ROOT ESP ROOTFS KERNEL ID; do [ -n "${!v}" ] || die "--${v,,} is required"; done
TITLE=${TITLE:-$ID}
[ "$(blkid -s PARTLABEL -o value "$ROOT")" != persist ] || die "refusing: $ROOT is persist"
[ "$(blkid -s TYPE -o value "$ESP")" = vfat ] || die "$ESP is not FAT (run partition-ufs.sh first)"
PARTUUID=$(blkid -s PARTUUID -o value "$ROOT"); [ -n "$PARTUUID" ] || die "no PARTUUID for $ROOT"
ESPUUID=$(blkid -s UUID -o value "$ESP")

M=$(mktemp -d); E=$(mktemp -d); K=$(mktemp -d)
cleanup() { umount "$M" 2>/dev/null || true; umount "$E" 2>/dev/null || true; rm -rf "$K"; rmdir "$M" "$E" 2>/dev/null || true; }
trap cleanup EXIT
mount "$ROOT" "$M"; mount "$ESP" "$E"
[ -z "$(ls -A "$M" | grep -v lost+found)" ] || { read -r -p "$ROOT is not empty. Wipe it? [y/N] " a; [ "$a" = y ] || die aborted; find "$M" -mindepth 1 -delete; }

echo "== rootfs"
if [ -d "$ROOTFS" ]; then cp -a "$ROOTFS"/. "$M"/
else command -v bsdtar >/dev/null && bsdtar -xpf "$ROOTFS" -C "$M" || tar -xpf "$ROOTFS" -C "$M" --numeric-owner; fi

echo "== kernel + modules"
tar -xzf "$KERNEL" -C "$K"
REL=$(ls "$K/usr/lib/modules"); [ -n "$REL" ] || die "no modules in $KERNEL"
rm -rf "$M/boot/vmlinuz-"* "$M/boot/Image"* 2>/dev/null || true   # distro kernels: not used (no UFS HS-G3 cap)
mkdir -p "$M/usr/lib/modules"; cp -a "$K/usr/lib/modules/$REL" "$M/usr/lib/modules/"
[ -L "$M/lib" ] || { mkdir -p "$M/lib/modules"; ln -sfn "/usr/lib/modules/$REL" "$M/lib/modules/$REL"; }
cp "$K/boot/config-$REL" "$M/boot/" 2>/dev/null || true
command -v depmod >/dev/null && depmod -b "$M/usr" "$REL" 2>/dev/null || depmod -b "$M" "$REL" 2>/dev/null || true
mkdir -p "$E/$ID"; cp "$K/boot/vmlinuz-$REL.efi" "$E/$ID/vmlinuz.efi"

if [ -n "$FW" ]; then echo "== firmware"; mkdir -p "$M/usr/lib/firmware"; cp -a "$FW"/. "$M/usr/lib/firmware/"; fi

echo "== fstab"
mkdir -p "$M/efi"
cat > "$M/etc/fstab" <<EOF
PARTUUID=$PARTUUID  /     ext4  rw,relatime  0 1
UUID=$ESPUUID       /efi  vfat  rw,relatime,fmask=0077,dmask=0077,noauto,x-systemd.automount  0 2
EOF

echo "== systemd-boot"
mkdir -p "$E/EFI/BOOT" "$E/loader/entries"
if [ ! -f "$E/EFI/BOOT/BOOTAA64.EFI" ]; then
  SRC=${SDBOOT:-$M/usr/lib/systemd/boot/efi/systemd-bootaa64.efi}
  [ -f "$SRC" ] || die "no systemd-bootaa64.efi (pass --sdboot; get it from Debian/Ubuntu package systemd-boot-efi:arm64)"
  cp "$SRC" "$E/EFI/BOOT/BOOTAA64.EFI"
  mkdir -p "$E/EFI/systemd"; cp "$SRC" "$E/EFI/systemd/systemd-bootaa64.efi"
fi
[ -f "$E/loader/loader.conf" ] || printf 'timeout 5\nconsole-mode keep\neditor yes\n' > "$E/loader/loader.conf"
DTLINE=
if [ -n "$DTB" ]; then
  # guacamole-dp.dtb stays as shipped; personalize-dtb.sh (on the phone) writes
  # guacamole.dtb from it with this phone's Wi-Fi/Bluetooth addresses. Until
  # then guacamole.dtb is a plain copy, so the entry boots either way.
  mkdir -p "$E/dtbs"
  cp "$DTB" "$E/dtbs/guacamole-dp.dtb"
  [ -f "$E/dtbs/guacamole.dtb" ] || cp "$DTB" "$E/dtbs/guacamole.dtb"
  DTLINE="devicetree /dtbs/guacamole.dtb"
fi
cat > "$E/loader/entries/$ID.conf" <<EOF
title   $TITLE
linux   /$ID/vmlinuz.efi
$DTLINE
options root=PARTUUID=$PARTUUID rw rootwait console=tty0 $EXTRA
EOF
sed -i '/^$/d' "$E/loader/entries/$ID.conf"
grep -q '^default' "$E/loader/loader.conf" || echo "default $ID.conf" >> "$E/loader/loader.conf"
# initramfs is optional (UFS + ext4 are built in); if you generate one, copy it
# to ESP/$ID/initrd.img and add "initrd /$ID/initrd.img" to the entry above.

if [ "$USBNET" = 1 ]; then
  echo "== USB network gadget (phone 10.66.0.1/24)"
  install -Dm755 "$(dirname "$0")/usb-gadget-net" "$M/usr/local/sbin/usb-gadget-net"
  install -Dm644 /dev/stdin "$M/etc/systemd/system/usb-gadget-net.service" <<'EOF'
[Unit]
Description=USB network gadget (10.66.0.1)
After=sys-kernel-config.mount systemd-udevd.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/usb-gadget-net
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  mkdir -p "$M/etc/systemd/system/multi-user.target.wants"
  ln -sf /etc/systemd/system/usb-gadget-net.service "$M/etc/systemd/system/multi-user.target.wants/usb-gadget-net.service"
  # systemd-networkd owns the link (static 10.66.0.1 + DHCP server for the PC);
  # keep NetworkManager (if any) away from it
  install -Dm644 "$(dirname "$0")/10-usb-gadget.network" "$M/etc/systemd/network/10-usb-gadget.network"
  mkdir -p "$M/etc/NetworkManager/conf.d"
  printf '[keyfile]\nunmanaged-devices=mac:02:66:00:00:00:01\n' > "$M/etc/NetworkManager/conf.d/10-usb-gadget.conf"
  if [ -e "$M/usr/lib/systemd/system/systemd-networkd.service" ]; then
    ln -sf /usr/lib/systemd/system/systemd-networkd.service "$M/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
  fi
fi

echo "== A/B slot marker (stops the OnePlus bootloader counting down to 'destroyed')"
install -Dm755 "$(dirname "$0")/ab-mark-successful" "$M/usr/local/sbin/ab-mark-successful"
install -Dm644 "$(dirname "$0")/ab-mark-successful.service" "$M/etc/systemd/system/ab-mark-successful.service"
mkdir -p "$M/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/ab-mark-successful.service "$M/etc/systemd/system/multi-user.target.wants/ab-mark-successful.service"

sync
echo "Installed '$TITLE' on $ROOT (PARTUUID=$PARTUUID), kernel $REL"
echo "ESP entries now:"; ls "$E/loader/entries"
