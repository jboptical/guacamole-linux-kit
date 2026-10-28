#!/usr/bin/env bash
# Update the USB-network gadget setup inside an already-installed rootfs.
#   sudo bash scripts/update-usbnet.sh /dev/sdX21
set -euo pipefail
ROOT="${1:?usage: $0 /dev/sdXN (the linuxN partition)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
M=$(mktemp -d); trap 'umount "$M" 2>/dev/null; rmdir "$M"' EXIT
mount "$ROOT" "$M"
[ -d "$M/etc" ] || { echo "$ROOT doesn't look like a Linux root"; exit 1; }
install -Dm755 "$HERE/usb-gadget-net" "$M/usr/local/sbin/usb-gadget-net"
install -Dm644 "$HERE/10-usb-gadget.network" "$M/etc/systemd/network/10-usb-gadget.network"
mkdir -p "$M/etc/NetworkManager/conf.d" "$M/etc/systemd/system/multi-user.target.wants"
printf '[keyfile]\nunmanaged-devices=mac:02:66:00:00:00:01\n' > "$M/etc/NetworkManager/conf.d/10-usb-gadget.conf"
sed -i 's/^After=sys-kernel-config.mount$/After=sys-kernel-config.mount systemd-udevd.service/' "$M/etc/systemd/system/usb-gadget-net.service" 2>/dev/null || true
if [ -e "$M/usr/lib/systemd/system/systemd-networkd.service" ]; then
  ln -sf /usr/lib/systemd/system/systemd-networkd.service "$M/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
fi
ls "$M/etc/systemd/system/multi-user.target.wants/" | grep -E "usb-gadget|networkd|sshd|ab-mark" || true
sync
echo "Updated USB networking on $ROOT"
