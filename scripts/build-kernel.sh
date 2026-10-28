#!/usr/bin/env bash
# Build the SM8150 mainline kernel (v6.17.0-sm8150 + guacamole_nura patches)
# as an EFI-bootable image for U-Boot -> systemd-boot/GRUB on the OnePlus 7 Pro.
#
#   sudo apt install build-essential clang lld llvm flex bison bc libssl-dev libelf-dev \
#                    git curl python3 cpio kmod
#   ./build-kernel.sh            # output: ./build/guacamole-kernel-<release>.tar.gz
#
# The tarball contains:
#   boot/vmlinuz-<rel>.efi   self-decompressing EFI kernel (CONFIG_EFI_ZBOOT)
#   boot/config-<rel>
#   usr/lib/modules/<rel>/   modules (copy into every distro rootfs)
#   boot/dtbs/qcom/sm8150-*.dtb
#
# WHY THIS KERNEL: stock distro kernels lack patch 0010 (UFS capped at HS-G3).
# At HS-G4 the 7 Pro's UFS link silently drops writes -> filesystem corruption.
# Do not mount the UFS read-write with a kernel that lacks this cap.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK="${WORK:-$PWD/build}"
# release suffix (6.17.0-sm8150-guac1). Bump it for every new build you
# install on a running phone (KSUFFIX=-guac2 ...), so update-kernel.sh puts it
# next to the current kernel instead of overwriting the running one's modules
KSUFFIX="${KSUFFIX:--guac1}"
TAG=v6.17.0-sm8150
SHA512=274270bb0391bca972b1dffae778ff6fc372457b658e9252104d9894c9f24739e25df7021378cf0ac9c650cc417d0cdcdf1baa88bfdcd494920ee183298e1f34
NURA_REF="${NURA_REF:-5b2241bb5c1bd0af2ce455a4efdabd7e8a5d9e24}"
mkdir -p "$WORK" && cd "$WORK"

[ -f linux-$TAG.tar.gz ] || curl -fL -o linux-$TAG.tar.gz \
  "https://gitlab.com/sm8150-mainline/linux/-/archive/$TAG/linux-$TAG.tar.gz"
echo "$SHA512  linux-$TAG.tar.gz" | sha512sum -c -

[ -d guacamole_nura ] || git clone https://github.com/emilyastranova/guacamole_nura.git
git -C guacamole_nura checkout -q "$NURA_REF" || echo "WARN: could not pin $NURA_REF"
PKG=guacamole_nura/device/testing/linux-postmarketos-qcom-sm8150

rm -rf linux-$TAG && tar xzf linux-$TAG.tar.gz
cd linux-$TAG
# apply patches in APKBUILD order
for p in $(awk '/^source="/,/^"/' "../$PKG/APKBUILD" | grep -o '[0-9]\{4\}-[^ ]*\.patch'); do
  echo "== $p"; patch -p1 -N --no-backup-if-mismatch < "../$PKG/$p"
done
# kit fixes on top (DisplayPort mode filtering, msm GEM free)
for p in "$HERE"/../patches-kernel/*.patch; do
  [ -e "$p" ] || continue
  echo "== kit: $(basename "$p")"; patch -p1 -N --no-backup-if-mismatch < "$p"
done
cp "../$PKG/config-postmarketos-qcom-sm8150.aarch64" .config
./scripts/config --set-str LOCALVERSION "-sm8150$KSUFFIX"
# make sure the bits EFI booting needs are on
./scripts/config -e EFI -e EFI_STUB -e EFI_ZBOOT -e EFIVAR_FS -e DMI -e DRM_SIMPLEDRM -e SYSFB_SIMPLEFB \
                 -e BLK_DEV_INITRD -e DEVTMPFS -e DEVTMPFS_MOUNT -e VFAT_FS -e NLS_CODEPAGE_437 -e NLS_ISO8859_1 \
                 -e AUTOFS_FS -e CGROUPS -e FANOTIFY -e TMPFS_POSIX_ACL -e TMPFS_XATTR \
                 -e SECURITY_LANDLOCK   # systemd distros; Landlock for pacman 7 sandbox
# the PM8150 RTC reads 1970 and cannot be set: never copy it into the system clock
./scripts/config -d RTC_HCTOSYS -d RTC_SYSTOHC
make ARCH=arm64 LLVM=1 olddefconfig
make ARCH=arm64 LLVM=1 -j"$(nproc)"
REL=$(make -s ARCH=arm64 LLVM=1 kernelrelease)

OUT="$WORK/stage-$REL"; rm -rf "$OUT"; mkdir -p "$OUT/boot/dtbs/qcom"
install -m644 arch/arm64/boot/vmlinuz.efi "$OUT/boot/vmlinuz-$REL.efi"
install -m644 .config "$OUT/boot/config-$REL"
install -m644 System.map "$OUT/boot/System.map-$REL"
make ARCH=arm64 LLVM=1 INSTALL_MOD_PATH="$OUT/usr" INSTALL_MOD_STRIP=1 modules_install
rm -f "$OUT"/usr/lib/modules/*/build "$OUT"/usr/lib/modules/*/source
cp arch/arm64/boot/dts/qcom/sm8150-*.dtb "$OUT/boot/dtbs/qcom/" 2>/dev/null || true
tar -C "$OUT" -czf "$WORK/guacamole-kernel-$REL.tar.gz" .
echo "Kernel release: $REL"
echo "Package: $WORK/guacamole-kernel-$REL.tar.gz"
