#!/bin/sh
# Run ON THE PHONE as root (Arch Linux ARM). Replaces systemd-timesyncd with
# chrony for NTP.
#
# Why: timesyncd only talks to time servers while systemd-networkd says the
# system is online, and networkd manages only the USB gadget link (Wi-Fi is
# NetworkManager's). With no USB cable networkd reports ONLINE_STATE=offline,
# so the clock never synced over Wi-Fi. chrony does not depend on networkd.
#
# There is no usable RTC: at boot systemd sets the clock from the mtime of
# /var/lib/systemd/timesync/clock, which timesyncd used to keep fresh. A timer
# (every 15 min) and chronyd's stop now touch that file instead.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "== 1/4 chrony"
pacman -S --needed --noconfirm chrony
# Arch's /etc/chrony.conf is used as is: pool 2.arch.pool.ntp.org iburst,
# makestep 1.0 3 (step the clock at start), rtcsync (marks the kernel clock
# synchronised for timedatectl; harmless, the RTC driver is not loaded)

echo "== 2/4 Wi-Fi and resume hooks (they restarted timesyncd, which chronyd conflicts with)"
install -Dm755 /dev/stdin /etc/NetworkManager/dispatcher.d/50-timesync <<'EOT'
#!/bin/sh
# NetworkManager dispatcher: $1 = interface, $2 = action
# Re-sync the clock when Wi-Fi comes up (chrony, or timesyncd if that is used)
case "$2" in
  up|dhcp4-change|connectivity-change)
    [ "$1" = usb0 ] && exit 0
    if systemctl -q is-active chronyd.service; then
      chronyc -a online >/dev/null 2>&1; chronyc -a burst 4/4 >/dev/null 2>&1
    elif systemctl -q is-enabled systemd-timesyncd.service; then
      systemctl restart --no-block systemd-timesyncd.service
    fi ;;
esac
exit 0
EOT
install -Dm755 /dev/stdin /usr/lib/systemd/system-sleep/50-timesync <<'EOT'
#!/bin/sh
# after resume: re-sync the clock (systemd-sleep hook: $1 = pre/post)
[ "$1" = post ] || exit 0
if systemctl -q is-active chronyd.service; then
  chronyc -a burst 4/4 >/dev/null 2>&1
elif systemctl -q is-enabled systemd-timesyncd.service; then
  systemctl restart --no-block systemd-timesyncd.service
fi
exit 0
EOT

echo "== 3/4 keep the boot-time clock file fresh"
mkdir -p /var/lib/systemd/timesync
touch /var/lib/systemd/timesync/clock
install -Dm644 /dev/stdin /etc/systemd/system/guacamole-clock-save.service <<'EOT'
[Unit]
Description=Save the time for the next boot (no RTC on the OnePlus 7 Pro)

[Service]
Type=oneshot
ExecStart=/usr/bin/touch /var/lib/systemd/timesync/clock
EOT
install -Dm644 /dev/stdin /etc/systemd/system/guacamole-clock-save.timer <<'EOT'
[Unit]
Description=Save the time every 15 minutes (no RTC on the OnePlus 7 Pro)

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOT
install -Dm644 /dev/stdin /etc/systemd/system/chronyd.service.d/50-guacamole-clock-save.conf <<'EOT'
[Service]
# shutdown: save the time for the next boot (chronyd's unit makes the
# filesystem read-only, so open this one directory, and never fail on it)
ReadWritePaths=/var/lib/systemd/timesync
ExecStopPost=-/usr/bin/touch /var/lib/systemd/timesync/clock
EOT

echo "== 4/4 switch"
systemctl daemon-reload
systemctl disable --now systemd-timesyncd.service 2>/dev/null || true
# masked: `timedatectl set-ntp true` would otherwise start timesyncd, which
# conflicts with chronyd and stops it (timedatectl then shows "NTP service: n/a")
systemctl mask systemd-timesyncd.service
systemctl enable --now chronyd.service guacamole-clock-save.timer
sleep 10
chronyc -n sources || true
chronyc tracking | grep -E "Reference|System time|Leap status" || true
timedatectl | grep -E "synchronized|NTP service"
