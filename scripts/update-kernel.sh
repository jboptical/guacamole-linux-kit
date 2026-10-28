#!/bin/sh
# Run ON THE PHONE as root. Installs a kernel package from build-kernel.sh NEXT
# TO the current kernel and adds a boot menu entry for it; the old kernel and
# its entries stay as they are, so a bad build is one menu choice away.
#
#   sh update-kernel.sh guacamole-kernel-<release>.tar.gz [template-entry]
#   template-entry: default /efi/loader/entries/arch.conf (its devicetree
#   and options lines are kept; title and linux are replaced)
# Then reboot, pick the new entry, and once happy make it the default:
#   sed -i 's/^default .*/default <id>-<release>.conf/' /efi/loader/loader.conf
set -eu
PKG=${1:?usage: $0 guacamole-kernel-<release>.tar.gz [template-entry]}
TEMPLATE=${2:-/efi/loader/entries/arch.conf}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -f "$PKG" ] || { echo "no $PKG"; exit 1; }
ls /efi >/dev/null 2>&1 || true            # trigger the ESP automount
[ -f "$TEMPLATE" ] || { echo "no template entry $TEMPLATE"; ls /efi/loader/entries; exit 1; }

ID=$(sed -n 's|^linux[[:space:]]*/\([^/]*\)/.*|\1|p' "$TEMPLATE")   # ESP folder, e.g. arch
[ -n "$ID" ] || { echo "cannot read the linux line of $TEMPLATE"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tar -xzf "$PKG" -C "$T"
REL=$(ls "$T/usr/lib/modules")
[ -n "$REL" ] && [ -f "$T/boot/vmlinuz-$REL.efi" ] || { echo "not a build-kernel.sh package"; exit 1; }
[ "$REL" != "$(uname -r)" ] || { echo "$REL is the running kernel; rebuild with another KSUFFIX"; exit 1; }

echo "== modules $REL"
rm -rf "/usr/lib/modules/$REL"
cp -a "$T/usr/lib/modules/$REL" /usr/lib/modules/
depmod "$REL"
cp "$T/boot/config-$REL" /boot/ 2>/dev/null || true

echo "== kernel -> /efi/$ID/vmlinuz-$REL.efi"
cp "$T/boot/vmlinuz-$REL.efi" "/efi/$ID/vmlinuz-$REL.efi"
E="/efi/loader/entries/$ID-$REL.conf"
sed -e "s|^title.*|title   $(sed -n 's/^title[[:space:]]*//p' "$TEMPLATE" | sed 's/ (.*)$//') ($REL)|" \
    -e "s|^linux .*|linux   /$ID/vmlinuz-$REL.efi|" "$TEMPLATE" > "$E"
sync
echo; cat "$E"; echo
echo "Reboot and pick \"$(sed -n 's/^title[[:space:]]*//p' "$E")\" in the boot menu."
echo "Make it the default once it works:"
echo "  sed -i 's/^default .*/default $ID-$REL.conf/' /efi/loader/loader.conf"
