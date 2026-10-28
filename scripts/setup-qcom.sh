#!/usr/bin/env bash
# Run ON THE PHONE as root (Arch Linux ARM). Normally run by setup-arch.sh,
# which also sets up internet access through the PC (PROXY) before Wi-Fi works:
#   bash setup-qcom.sh [guacamole-firmware.tar.gz]
#
# Installs: device firmware tarball (from build-firmware.sh), linux-firmware
# (ath10k firmware-5.bin, Adreno sqe/gmu), the Qualcomm userspace helpers
# (libqrtr, rmtfs, tqftpserv - pd-mapper is in-kernel), a service that boots the
# MPSS modem once they run (Wi-Fi on WCN3990 goes through the modem), bluez for
# Bluetooth, and systemd-resolved. Wi-Fi itself is set up by setup-network.sh.
set -euo pipefail
FWTAR="${1:-guacamole-firmware.tar.gz}"
PROXY="${PROXY:-}"          # e.g. socks5h://127.0.0.1:1080 (ssh -R 1080 from the PC)
[ -z "$PROXY" ] || export all_proxy="$PROXY" https_proxy="$PROXY" http_proxy="$PROXY"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
# the phone has no usable RTC: the clock starts at 1970 until NTP runs, which
# breaks TLS and package signature checks
[ "$(date +%Y)" -ge 2025 ] || { echo "clock is wrong ($(date)). Set it first, e.g.: date -s \"2026-10-22 14:30\""; exit 1; }

echo "== 1/6 device firmware"
if [ -f "$FWTAR" ]; then
  tar -xzf "$FWTAR" -C / --no-same-owner --no-overwrite-dir --touch
  echo "installed $(tar -tzf "$FWTAR" | grep -vc '/$') files"
else
  echo "WARNING: $FWTAR not found - copy it from the PC first (scp build/guacamole-firmware.tar.gz alarm@10.66.0.1:)"
fi

echo "== 2/6 packages"
PKGS="base-devel git meson ninja pkgconf xz zstd systemd-libs iw wireless-regdb bluez bluez-utils dtc"
if pacman -Si linux-firmware-qcom >/dev/null 2>&1; then
  PKGS="$PKGS linux-firmware-qcom linux-firmware-atheros"
else
  PKGS="$PKGS linux-firmware"
fi
# -Syu, not -S: a stale package list asks the mirror for versions it no longer has (404)
pacman -Syu --needed --noconfirm $PKGS

echo "== 3/6 build libqrtr, rmtfs, tqftpserv"
SRC=/root/qcom-src; mkdir -p "$SRC"; cd "$SRC"
for r in qrtr rmtfs tqftpserv; do
  [ -d "$r" ] || git ${PROXY:+-c http.proxy="$PROXY"} clone --depth 1 "https://github.com/linux-msm/$r"
done
( cd qrtr && meson setup build --prefix=/usr --wipe >/dev/null && ninja -C build install )
ldconfig
( cd rmtfs && make clean >/dev/null 2>&1; make prefix=/usr && make prefix=/usr install )
( cd tqftpserv && meson setup build --prefix=/usr -Dsystemd-unit-prefix=/usr/lib/systemd/system --wipe >/dev/null && ninja -C build install )

echo "== 4/6 MPSS (modem) start service"
install -Dm755 /dev/stdin /usr/local/sbin/guacamole-mpss <<'EOF'
#!/bin/sh
# Boot the MPSS remoteproc (needed for WCN3990 Wi-Fi) after rmtfs/tqftpserv run.
RP=""
for d in /sys/class/remoteproc/remoteproc*; do
  case "$(cat $d/firmware 2>/dev/null)" in *modem.mdt) RP=$d ;; esac
done
[ -n "$RP" ] || { echo "no MPSS remoteproc found"; exit 1; }
state=$(cat $RP/state)
echo "MPSS $RP: $state"
[ "$state" = running ] && exit 0
[ "$state" = crashed ] && echo stop > $RP/state 2>/dev/null
echo start > $RP/state
for i in $(seq 1 30); do
  state=$(cat $RP/state)
  [ "$state" = running ] && { echo "MPSS running"; exit 0; }
  [ "$state" = crashed ] && { echo "MPSS crashed"; exit 1; }
  sleep 1
done
echo "MPSS did not start (state: $state)"; exit 1
EOF
cat > /etc/systemd/system/guacamole-mpss.service <<'EOF'
[Unit]
Description=Boot Qualcomm MPSS modem (WCN3990 Wi-Fi)
Wants=rmtfs.service tqftpserv.service
After=rmtfs.service tqftpserv.service
[Service]
Type=oneshot
ExecStartPre=/bin/sleep 3
ExecStart=/usr/local/sbin/guacamole-mpss
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

# SLPI (sensor DSP) crash-loops every ~40 s ("USER-PD DOG detects stalled
# initialization") until hexagonrpcd serves it the sensor libraries from the
# stock dsp partition. Stop it after boot until sensors are set up.
install -Dm755 /dev/stdin /usr/local/sbin/guacamole-slpi-off <<'EOF'
#!/bin/sh
for d in /sys/class/remoteproc/remoteproc*; do
  case "$(cat $d/firmware 2>/dev/null)" in
    *slpi.mdt) [ "$(cat $d/state)" = offline ] || echo stop > $d/state; echo "SLPI ($d) stopped" ;;
  esac
done
EOF
cat > /etc/systemd/system/guacamole-slpi-off.service <<'EOF'
[Unit]
Description=Stop SLPI sensor DSP (crash-loops without hexagonrpcd sensor files)
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/guacamole-slpi-off
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

echo "== 5/6 DNS (systemd-resolved)"
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "== 6/6 enable services"
systemctl daemon-reload
systemctl enable rmtfs tqftpserv guacamole-mpss guacamole-slpi-off systemd-resolved bluetooth
echo
echo "Done (Qualcomm support). Wi-Fi starts after the next reboot; see setup-network.sh."
