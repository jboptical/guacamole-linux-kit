#!/usr/bin/env bash
# Run ON THE PHONE as root (Arch Linux ARM), after setup-qcom.sh (normally run
# by setup-arch.sh). Wi-Fi through NetworkManager, for desktop and headless
# installs alike:
#   - NetworkManager with the wpa_supplicant backend (not iwd: through iwd,
#     NetworkManager makes up the access-point data it reports, e.g. every
#     network at 2417 MHz with fake BSSIDs)
#   - the USB network gadget (usb0, 10.66.0.1) stays with systemd-networkd,
#     so SSH over the cable works whatever NetworkManager does
#   - Wi-Fi power save off: with it on, the WCN3990 sleeps between beacons and
#     everything sent to the phone waits up to ~100 ms (pings 2-125 ms instead
#     of 2-3 ms). Costs about 0.3 W. WIFI_POWERSAVE=on keeps power save.
#
#   bash setup-network.sh
# Connect after the next reboot (Wi-Fi needs the modem, which starts at boot):
#   nmcli device wifi connect "<SSID>" --ask
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "== 1/3 packages"
pacman -S --needed --noconfirm networkmanager wpa_supplicant iw wireless-regdb

echo "== 2/3 NetworkManager configuration"
mkdir -p /etc/NetworkManager/conf.d
printf '[device]\nwifi.backend=wpa_supplicant\n' > /etc/NetworkManager/conf.d/10-wifi-backend.conf
printf '[keyfile]\nunmanaged-devices=mac:02:66:00:00:00:01\n' > /etc/NetworkManager/conf.d/10-usb-gadget.conf
if [ "${WIFI_POWERSAVE:-off}" = off ]; then
  install -m644 "$HERE/nm-conf/20-wifi-powersave-off.conf" /etc/NetworkManager/conf.d/20-wifi-powersave-off.conf
fi
# Wi-Fi regulatory domain (channels and power allowed in your country):
# REGDOM=US bash setup-network.sh, or edit the file later
if [ -n "${REGDOM:-}" ]; then
  echo "options cfg80211 ieee80211_regdom=$REGDOM" > /etc/modprobe.d/cfg80211-regdom.conf
fi
# systemd-networkd only handles the USB gadget; its wait-online would wait 2
# minutes at every boot without a USB cable and delay everything after
# network-online.target. NetworkManager-wait-online covers Wi-Fi.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true

echo "== 3/3 services"
systemctl disable iwd.service 2>/dev/null || true
systemctl enable NetworkManager.service NetworkManager-dispatcher.service

echo
echo "Done. After the reboot, connect Wi-Fi with:"
echo "  nmcli device wifi connect \"<SSID>\" --ask"
