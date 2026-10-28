#!/usr/bin/env bash
# Run ON THE PHONE as root, on the first boot of a fresh Arch Linux ARM
# install made by install-arch.sh. Sets up everything that makes the OnePlus 7
# Pro work, then asks for a reboot:
#
#   bash setup-arch.sh [--gui | --headless] [--no-sensors] [--no-tools] [--regdom CC]
#
#   --gui        KDE Plasma (desktop + Plasma Mobile) with SDDM and an on-screen
#                keyboard, plus the Guacamole Panel / Server Monitor apps
#   --headless   no desktop: boots to a console, SSH and Wi-Fi via nmcli; the
#                guac CLI and battery care are still installed
#   (default: what install-arch.sh was given, else --gui)
#   --no-sensors skip the sensor DSP setup (auto-rotate, light, proximity)
#   --no-tools   skip guacamole-tools (battery care, thermal limits, guac CLI, apps)
#   --regdom CC  Wi-Fi country code, e.g. US, GB, DE, AU
#
# Before Wi-Fi works the phone has no internet, so give it the PC's through
# the USB cable: connect with  ssh -R 1080 alarm@10.66.0.1  and run this in
# that session (after su). It uses that SOCKS proxy when it is there.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$HERE/.." && pwd)
MODE= SENSORS=1 TOOLS=1 REGDOM=
[ -f "$KIT/setup.conf" ] && . "$KIT/setup.conf"
while [ $# -gt 0 ]; do case "$1" in
  --gui) MODE=gui; shift;; --headless) MODE=headless; shift;;
  --no-sensors) SENSORS=0; shift;; --no-tools) TOOLS=0; shift;;
  --regdom) REGDOM=$2; shift 2;;
  *) echo "unknown arg $1 (see the top of this script)"; exit 2;; esac; done
MODE=${MODE:-gui}
[ "$(id -u)" = 0 ] || { echo "run as root (su)"; exit 1; }
LOG=/root/guacamole-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "== guacamole setup ($MODE) $(date)"

# --- internet through the PC (ssh -R 1080) until Wi-Fi works ---------------
PROXY=
if (exec 3<>/dev/tcp/127.0.0.1/1080) 2>/dev/null; then
  PROXY=socks5h://127.0.0.1:1080
  echo "using the PC's SOCKS proxy on 127.0.0.1:1080"
  export all_proxy=$PROXY https_proxy=$PROXY http_proxy=$PROXY
  # pacman's own downloader ignores proxies: hand downloads to curl for now
  # (and no download sandbox, which may not let curl reach the proxy)
  # (removed again on exit; only these two lines, so later changes such as
  # the IgnorePkg below stay)
  sed -i '/^\[options\]/a XferCommand = /usr/bin/curl --socks5-hostname 127.0.0.1:1080 -L -C - -f -o %o %u\nDisableSandbox' /etc/pacman.conf
  trap "sed -i -e '\\|^XferCommand = /usr/bin/curl --socks5-hostname 127.0.0.1:1080 |d' -e '/^DisableSandbox\$/d' /etc/pacman.conf" EXIT
fi
export PROXY
curl -fsI -m 10 http://os.archlinuxarm.org >/dev/null ||
  { echo "no internet: connect with  ssh -R 1080 alarm@10.66.0.1  from the PC and run this in that session"; exit 1; }

# --- clock: there is no usable RTC, the phone starts in 1970 ----------------
if [ "$(date +%Y)" -lt 2025 ]; then
  d=$(curl -fsI -m 10 http://os.archlinuxarm.org | sed -n 's/^[Dd]ate: //p' | tr -d '\r')
  [ -n "$d" ] && date -s "$d" >/dev/null && echo "clock set from the mirror: $(date)"
fi
[ "$(date +%Y)" -ge 2025 ] || { echo "clock is wrong ($(date)); set it: date -s \"YYYY-MM-DD hh:mm\""; exit 1; }

echo "== pacman keyring"
pacman-key --init
pacman-key --populate archlinuxarm

# Arch's own kernel can never be booted here (no UFS HS-G3 cap: it would corrupt
# the filesystem); remove it so updates don't rebuild it and its initramfs
if pacman -Q linux-aarch64 >/dev/null 2>&1; then
  echo "== removing the stock kernel package (linux-aarch64)"
  pacman -Rdd --noconfirm linux-aarch64
  for d in /usr/lib/modules/*-ARCH; do [ -d "$d" ] && rm -rf "$d"; done
fi
grep -q '^IgnorePkg.*linux-aarch64' /etc/pacman.conf ||
  sed -i '/^\[options\]/a IgnorePkg = linux-aarch64 linux-aarch64-headers' /etc/pacman.conf

step() { echo; echo "######## $*"; }
step "Qualcomm support (firmware, rmtfs/tqftpserv/qrtr, modem for Wi-Fi)"
bash "$HERE/setup-qcom.sh" "$KIT/guacamole-firmware.tar.gz"
step "Network (NetworkManager)"
REGDOM=$REGDOM bash "$HERE/setup-network.sh"
step "Wi-Fi/Bluetooth addresses in the device tree"
sh "$HERE/personalize-dtb.sh" || echo "WARNING: personalize-dtb.sh failed; Wi-Fi gets a random MAC each boot"
step "Audio"
sh "$HERE/setup-audio.sh"
# Restoring the brightness early in boot can collide with a panel frame
# transfer (DSI FIFO error) and leave coloured static on screen until the next
# sleep/wake; the desktop sets the brightness itself later anyway.
systemctl mask systemd-backlight@backlight:ae94000.dsi.0.service
step "Time sync (chrony)"
sh "$HERE/setup-chrony.sh"
if [ "$SENSORS" = 1 ]; then
  step "Sensors"
  sh "$HERE/setup-sensors.sh"
fi
if [ "$MODE" = gui ]; then
  step "Desktop (KDE Plasma)"
  bash "$HERE/setup-desktop-arch.sh"
else
  systemctl set-default multi-user.target
fi
if [ "$TOOLS" = 1 ]; then
  step "guacamole-tools"
  if [ "$MODE" = gui ]; then sh "$KIT/guacamole-tools/install-guacamole-tools.sh"
  else HEADLESS=1 sh "$KIT/guacamole-tools/install-guacamole-tools.sh"; fi
fi

echo
echo "All done ($MODE). Log: $LOG"
echo "Reboot now:  systemctl reboot"
echo "Then connect Wi-Fi:  nmcli device wifi connect \"<SSID>\" --ask   (or the network icon)"
echo "Change the passwords:  passwd alarm; passwd root"
