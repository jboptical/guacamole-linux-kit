#!/bin/sh
# Run ON THE PHONE as root (Arch Linux ARM or Ubuntu/Debian), from this folder:
#   sh install-guacamole-tools.sh            # with the GTK apps
#   HEADLESS=1 sh install-guacamole-tools.sh # no desktop: battery care + guac CLI only
# Installs guacamole-chgctrl (charge policy + battery-care window),
# guacamole-thermal (lower CPU/GPU throttling points), the guac CLI, their
# root helper + polkit rule and, unless HEADLESS=1, Guacamole Panel (the
# monitoring/control app) and Server Monitor (full-screen status page, opened
# at login while server mode is on).
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
cd "$(dirname "$0")"
HEADLESS=${HEADLESS:-0}
for f in guacamole-chgctrl guacamole-chgctrl.service chgctrl.conf guacamole-helper \
         org.guacamole.helper.policy guacamole_common.py guac \
         guacamole-thermal guacamole-thermal.service; do
  [ -f "$f" ] || { echo "missing $f (copy the whole guacamole-tools folder)"; exit 1; }
done
[ "$HEADLESS" = 1 ] || for f in guacamole-panel org.guacamole.Panel.desktop guacamole-monitor \
         org.guacamole.Monitor.desktop org.guacamole.Monitor-autostart.desktop; do
  [ -f "$f" ] || { echo "missing $f (copy the whole guacamole-tools folder)"; exit 1; }
done

echo "== dependencies"
if command -v pacman >/dev/null; then
  if [ "$HEADLESS" = 1 ]; then
    pacman -S --needed --noconfirm python polkit iw iproute2
  else
    pacman -S --needed --noconfirm python python-gobject gtk4 libadwaita polkit iw iproute2
  fi
elif command -v apt-get >/dev/null; then
  if [ "$HEADLESS" = 1 ]; then
    apt-get install -y python3 iw iproute2
  else
    apt-get install -y python3 python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 pkexec iw iproute2 ||
      apt-get install -y python3 python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 policykit-1 iw iproute2
  fi
else
  echo "unknown distro: install python3 (+ PyGObject, GTK 4, libadwaita, polkit for the apps) yourself"
fi

echo "== files"
install -Dm755 guacamole-chgctrl /usr/local/libexec/guacamole-chgctrl
install -Dm755 guacamole-helper /usr/local/libexec/guacamole-helper
ln -sfn /usr/local/libexec/guacamole-chgctrl /usr/local/bin/guacamole-chgctrl
install -Dm644 guacamole_common.py /usr/local/lib/guacamole/guacamole_common.py
install -Dm755 guac /usr/local/bin/guac
install -Dm644 org.guacamole.helper.policy /usr/share/polkit-1/actions/org.guacamole.helper.policy
install -Dm644 guacamole-chgctrl.service /etc/systemd/system/guacamole-chgctrl.service
if [ "$HEADLESS" != 1 ]; then
  install -Dm755 guacamole-panel /usr/local/bin/guacamole-panel
  install -Dm644 org.guacamole.Panel.desktop /usr/share/applications/org.guacamole.Panel.desktop
  install -Dm755 guacamole-monitor /usr/local/bin/guacamole-monitor
  install -Dm644 org.guacamole.Monitor.desktop /usr/share/applications/org.guacamole.Monitor.desktop
  # opens the monitor at login, but only while server mode (keep awake) is on
  install -Dm644 org.guacamole.Monitor-autostart.desktop /etc/xdg/autostart/org.guacamole.Monitor-autostart.desktop
fi
# lower thermal throttling points (CPU/GPU from 80 °C), set at every boot
install -Dm755 guacamole-thermal /usr/local/libexec/guacamole-thermal
install -Dm644 guacamole-thermal.service /etc/systemd/system/guacamole-thermal.service
if [ ! -f /etc/guacamole/thermal.conf ]; then
  mkdir -p /etc/guacamole
  printf '%s\n' "# guacamole-thermal (°C): CPUs throttle from CPU_TRIP, harder from CPU_TRIP2; GPU from GPU_TRIP" \
    "# (kernel defaults 90 / 95 / 85; the 110 °C emergency shutdown is not changed)" \
    "CPU_TRIP=80" "CPU_TRIP2=85" "GPU_TRIP=80" > /etc/guacamole/thermal.conf
fi
if [ -f /etc/guacamole/chgctrl.conf ]; then
  echo "keeping existing /etc/guacamole/chgctrl.conf"
else
  install -Dm644 chgctrl.conf /etc/guacamole/chgctrl.conf
fi

echo "== services"
systemctl daemon-reload
systemctl enable guacamole-chgctrl.service
systemctl restart guacamole-chgctrl.service
if ls /sys/class/thermal/thermal_zone*/type >/dev/null 2>&1; then
  systemctl enable guacamole-thermal.service
  systemctl restart guacamole-thermal.service
fi
sleep 6
/usr/local/bin/guacamole-chgctrl status || true
echo
echo "Done."
[ "$HEADLESS" = 1 ] || echo "Open \"Guacamole Panel\" from the app launcher (or run guacamole-panel)."
echo "In a terminal: guac (guac --help)."
echo "Log: journalctl -u guacamole-chgctrl -f"
