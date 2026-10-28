#!/bin/sh
# Run ON THE PHONE as root (Arch Linux ARM), from the linux-kit folder:
#   sh scripts/setup-sensors.sh
# Sensors (accelerometer for auto-rotate, light, proximity) through the SLPI
# sensor DSP, following guacamole_nura (see sensors/NURA_COMMIT):
#   SLPI remoteproc -> /dev/fastrpc-sdsp -> hexagonrpcd (serves /usr/share/qcom)
#   -> iio-sensor-proxy (libssc, QMI over QRTR) -> net.hadess.SensorProxy -> KWin
# Reads the stock vendor_b and dsp_b partitions READ-ONLY (ro,noload) for the
# sensor config and DSP libraries, and persist with debugfs (never mounted).
# Needs a reboot afterwards: the SLPI cannot be restarted hot.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
KIT=$(cd "$(dirname "$0")/.." && pwd)
S="$KIT/sensors"
[ -f "$S/hexagonrpcd/0001-serve-writable-files.patch" ] || { echo "missing $S (copy the whole linux-kit folder)"; exit 1; }

echo "== 1/6 packages"
pacman -S --needed --noconfirm base-devel meson curl e2fsprogs iio-sensor-proxy libssc qt6-sensors

echo "== 2/6 fastrpc user"
install -Dm644 /dev/stdin /etc/sysusers.d/fastrpc.conf <<'EOT'
u fastrpc - "FastRPC" /var/lib/fastrpc /usr/bin/nologin
EOT
systemd-sysusers /etc/sysusers.d/fastrpc.conf

echo "== 3/6 hexagonrpcd 0.4.0 + nura/hotdog patches -> /usr/local"
B=$(mktemp -d); trap 'rm -rf "$B"' EXIT
curl -fsSL -o "$B/h.tar.gz" https://github.com/linux-msm/hexagonrpc/archive/refs/tags/v0.4.0.tar.gz
echo "$(cat "$S/hexagonrpcd/hexagonrpcd-0.4.0.tar.gz.sha512")  $B/h.tar.gz" | sha512sum -c -
tar xzf "$B/h.tar.gz" -C "$B"
cd "$B/hexagonrpc-0.4.0"
for p in "$S"/hexagonrpcd/systemd-services.patch "$S"/hexagonrpcd/000*.patch; do
  echo "   $(basename "$p")"; patch -p1 -s < "$p"
done
# rpath: Arch's loader does not search /usr/local/lib for libhexagonrpc
meson setup --prefix=/usr/local --buildtype=release -Dc_link_args=-Wl,-rpath,/usr/local/lib build >/dev/null
meson compile -C build >/dev/null
meson install -C build --no-rebuild >/dev/null
cd "$KIT"
install -Dm644 "$S/hexagonrpcd/10-fastrpc.rules" /etc/udev/rules.d/10-fastrpc.rules

echo "== 4/6 files the sensor DSP needs (/usr/share/qcom)"
Q=/usr/share/qcom
M=$(mktemp -d)
rm -rf "$Q/sensors/config" "$Q/sdsp"
mkdir -p "$Q/sensors" "$Q/socinfo"
mount -o ro,noload /dev/disk/by-partlabel/vendor_b "$M"
cp -r "$M/etc/sensors/config" "$Q/sensors/config"
install -m644 "$M/etc/sensors/sns_reg_config" "$Q/sensors/sns_reg.conf"
umount "$M"
mount -o ro,noload /dev/disk/by-partlabel/dsp_b "$M"
cp -r "$M/sdsp" "$Q/sdsp"
umount "$M"; rmdir "$M"
printf MTP > "$Q/socinfo/hw_platform"
printf 339 > "$Q/socinfo/soc_id"
printf Unknown > "$Q/socinfo/platform_subtype"
printf 0 > "$Q/socinfo/platform_subtype_id"
printf 65536 > "$Q/socinfo/platform_version"
printf 2.2 > "$Q/socinfo/revision"
ln -sfn /var/lib/guacamole/sensors/registry "$Q/sensors/registry"
ln -sfn /var/lib/guacamole/sensors/project_info "$Q/project_info"
for f in sns_reg_version file1 file2; do ln -sfn "/var/lib/guacamole/sensors/$f" "$Q/sensors/$f"; done
find "$Q" -type f -exec chmod 644 {} +
echo "   $(find "$Q/sensors/config" -type f | wc -l) sensor configs, $(ls "$Q/sdsp" | wc -l) DSP libraries"

echo "== 5/6 registry import, udev rules, service order"
install -Dm755 "$S/guacamole-sensors-registry" /usr/local/libexec/guacamole-sensors-registry
sed 's|/usr/libexec/guacamole-sensors-registry|/usr/local/libexec/guacamole-sensors-registry|' \
  "$S/guacamole-sensors-registry.service" > /etc/systemd/system/guacamole-sensors-registry.service
install -Dm644 "$S/90-guacamole-sensors.rules" /etc/udev/rules.d/90-guacamole-sensors.rules
install -Dm644 "$S/61-guacamole-accel-mount-matrix.rules" /etc/udev/rules.d/61-guacamole-accel-mount-matrix.rules
install -Dm644 "$S/81-guacamole-ssc-types.rules" /etc/udev/rules.d/81-guacamole-ssc-types.rules
install -Dm644 "$S/iio-sensor-proxy-guacamole.conf" /etc/systemd/system/iio-sensor-proxy.service.d/guacamole.conf
/usr/local/libexec/guacamole-sensors-registry

echo "== 6/6 let the SLPI run"
# guacamole-slpi-off only existed because the SLPI crash-looped with nothing serving it
systemctl disable guacamole-slpi-off.service 2>/dev/null || true
systemctl daemon-reload
udevadm control --reload

echo
echo "Done. Reboot (the SLPI cannot be restarted hot). After about 30 s:"
echo "  systemctl status hexagonrpcd-sdsp iio-sensor-proxy"
echo "  sudo monitor-sensor --accel      (screen awake)"
echo "If the SLPI misbehaves, re-enable guacamole-slpi-off and reboot."
