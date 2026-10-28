#!/bin/sh
# Run ON THE PHONE as root. Bakes this phone's factory addresses into a DTB on
# the ESP, so every distro booted with it gets them without any helper:
#   Wi-Fi:      local-mac-address  (ath10k otherwise logs "invalid MAC address;
#                                   choosing random" and changes MAC every boot)
#   Bluetooth:  local-bd-address   (otherwise the controller registers as
#                                   unconfigured and BlueZ ignores it)
# The factory Wi-Fi MAC is Intf0MacAddress in wlan_mac.bin on the persist
# partition; Bluetooth uses it with the last byte + 1 (same as guacamole_nura).
#
#   sh personalize-dtb.sh [IN.dtb] [OUT.dtb]
#   default: /efi/dtbs/guacamole-dp.dtb -> /efi/dtbs/guacamole.dtb
# Needs fdtput (Arch/Fedora: dtc, Debian/Ubuntu: device-tree-compiler) and
# debugfs (e2fsprogs). Persist is only read, never mounted.
set -eu
IN=${1:-/efi/dtbs/guacamole-dp.dtb}
OUT=${2:-/efi/dtbs/guacamole.dtb}
PERSIST=${PERSIST:-/dev/disk/by-partlabel/persist}
WIFI=/soc@0/wifi@18800000
BT=/soc@0/geniqup@cc0000/serial@c8c000/bluetooth

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
for t in fdtput fdtget debugfs; do
  command -v $t >/dev/null || { echo "missing $t (install dtc / device-tree-compiler and e2fsprogs)"; exit 1; }
done
ls /efi >/dev/null 2>&1 || true          # trigger the ESP automount
[ -f "$IN" ] || { echo "no $IN"; exit 1; }
fdtget "$IN" $WIFI compatible >/dev/null && fdtget "$IN" $BT compatible >/dev/null

is_mac() {
  case "$1" in
    000000000000) return 1 ;;
    [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]) return 0 ;;
    *) return 1 ;;
  esac
}
# Source of the address, in order:
#  1. MAC=AA:BB:CC:DD:EE:FF in the environment (e.g. the factory MAC if known)
#  2. Intf0MacAddress in persist/wlan_mac.bin (Android writes it from modem NV;
#     after an MSM Download Tool restore it is often empty)
#  3. a stable address derived from the SoC serial number: locally administered
#     unicast, unique to this phone, identical in every distro
src=""
mac=$(echo "${MAC:-}" | tr -d ':-' | tr 'a-f' 'A-F')
is_mac "$mac" && src="MAC variable"
if [ -z "$src" ]; then
  mac=$(debugfs -R "cat /wlan_mac.bin" "$PERSIST" 2>/dev/null |
        sed -n 's/^Intf0MacAddress=//p' | tr -d '\r\n ' | tr 'a-f' 'A-F')
  is_mac "$mac" && src="persist wlan_mac.bin"
fi
if [ -z "$src" ]; then
  serial=$(cat /sys/devices/soc0/serial_number 2>/dev/null || true)
  [ -n "$serial" ] || { echo "no MAC in persist and no /sys/devices/soc0/serial_number; pass MAC=..."; exit 1; }
  h=$(printf 'guacamole-wlan-%s' "$serial" | sha256sum | cut -c1-12 | tr 'a-f' 'A-F')
  first=$(printf '%02X' $(( (0x$(echo "$h" | cut -c1-2) & 0xFC) | 0x02 )))
  mac="$first$(echo "$h" | cut -c3-12)"
  src="derived from SoC serial (persist has no factory MAC)"
fi

bytes=$(echo "$mac" | sed 's/../& /g')                 # AA BB CC DD EE FF
set -- $bytes
btlast=$(printf '%02X' $(( (0x$6 + 1) & 0xff )))
btrev="$btlast $5 $4 $3 $2 $1"                         # bdaddr_t is little-endian

tmp="$OUT.tmp"
cp "$IN" "$tmp"
fdtput -t bx "$tmp" $WIFI local-mac-address $bytes
fdtput -t bx "$tmp" $BT local-bd-address $btrev
mv "$tmp" "$OUT"
sync
echo "Wi-Fi MAC   $(echo $bytes | tr ' ' :)   ($src)"
echo "BT address  $1:$2:$3:$4:$5:$btlast"
echo "wrote $OUT (from $IN)"
