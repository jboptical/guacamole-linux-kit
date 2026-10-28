#!/usr/bin/env bash
# Run ON THE PHONE as root (Arch Linux ARM), after setup-network.sh (normally
# run by setup-arch.sh --gui). Installs KDE Plasma:
#   - "Plasma" session: full desktop, for the dock + external monitor
#   - "Plasma Mobile" session: touch shell for the phone screen alone
# SDDM login screen on Wayland (KWin) with an on-screen keyboard, the Plasma
# network applet, PipeWire, Mesa freedreno/turnip for the Adreno 640. USB
# networking (10.66.0.1) is left to systemd-networkd, so SSH keeps working
# whatever happens to the desktop.
#
#   bash setup-desktop-arch.sh        then: systemctl reboot
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ "$(date +%Y)" -ge 2025 ] || { echo "clock is wrong ($(date)); connect Wi-Fi or date -s first"; exit 1; }

WANT="plasma-desktop plasma-mobile plasma-nm plasma-pa powerdevil kscreen bluedevil
      systemsettings kde-gtk-config breeze-gtk xdg-desktop-portal-kde kwalletmanager
      sddm sddm-kcm plasma-keyboard maliit-keyboard
      konsole dolphin kate ark spectacle gwenview firefox
      mesa mesa-utils vulkan-freedreno vulkan-tools
      pipewire pipewire-pulse wireplumber
      networkmanager wpa_supplicant noto-fonts noto-fonts-emoji"

echo "== 1/3 packages"
pacman -Sy
PKGS=""; MISSING=""
for p in $WANT; do
  if pacman -Si "$p" >/dev/null 2>&1; then PKGS="$PKGS $p"; else MISSING="$MISSING $p"; fi
done
[ -z "$MISSING" ] || echo "not in the repos, skipped:$MISSING"
pacman -Su --needed --noconfirm $PKGS

echo "== 2/3 SDDM on Wayland with on-screen keyboard"
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-guacamole.conf <<'EOF'
[General]
DisplayServer=wayland
# the on-screen keyboard comes from KWin (/etc/xdg/kwinrc below), not Qt's
# in-process keyboard, which does not show in the Wayland greeter
InputMethod=
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1

[Theme]
Current=breeze
EOF

# On-screen keyboard for KWin (login screen, desktop, lock screen): Plasma's own
# plasma-keyboard (Arch ARM has no maliit-keyboard), else maliit if present.
# System default in /etc/xdg; a user's own kwinrc setting overrides it.
KBD=""
for pkg in plasma-keyboard maliit-keyboard; do
  pacman -Q $pkg >/dev/null 2>&1 || continue
  # the input-method launcher, not the package's settings page (kcm_*.desktop)
  files=$(pacman -Ql $pkg | awk '/\/usr\/share\/applications\/.*\.desktop$/ {print $2}')
  KBD=$(grep -l '^X-KDE-Wayland-VirtualKeyboard=true' $files 2>/dev/null | head -1 || true)
  [ -n "$KBD" ] || KBD=$(echo "$files" | grep -v '/kcm_' | head -1)
  [ -n "$KBD" ] && break
done
if [ -n "$KBD" ]; then
  kwriteconfig6 --file /etc/xdg/kwinrc --group Wayland --key InputMethod "$KBD"
  echo "virtual keyboard: $KBD"
else
  echo "WARNING: no virtual keyboard package found"
fi

# UTF-8 locale (Qt complains under the default C locale)
LOCALE=${LOCALE:-en_US.UTF-8}
if ! locale -a 2>/dev/null | grep -qi "^${LOCALE%.*}.utf8$"; then
  sed -i "s/^#\(${LOCALE} UTF-8\)/\1/" /etc/locale.gen && locale-gen
fi
localectl set-locale LANG="$LOCALE" || echo "LANG=$LOCALE" > /etc/locale.conf
# Plasma takes LANG from the user's plasma-localerc over /etc/locale.conf; a
# LANG=C left there from a session started before the locale existed sticks
rc=/home/alarm/.config/plasma-localerc
if [ -f "$rc" ] && grep -q '^LANG=C$' "$rc"; then
  sed -i "s/^LANG=C$/LANG=$LOCALE/" "$rc"; echo "fixed LANG=C in $rc"
fi

echo "== 3/3 services"
systemctl enable NetworkManager sddm bluetooth
systemctl set-default graphical.target

echo
echo "Done. Reboot (systemctl reboot). SSH over USB (10.66.0.1) keeps working."
echo "Log in as alarm; pick the session (Plasma / Plasma Mobile) on the login screen."
