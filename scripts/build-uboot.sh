#!/usr/bin/env bash
# Rebuild u-boot-guacamole.img from source (Linux or WSL2, Ubuntu/Debian).
#   sudo apt install gcc-aarch64-linux-gnu device-tree-compiler flex bison \
#        libssl-dev libgnutls28-dev uuid-dev python3-pyelftools swig bc xxd git
#   ./build-uboot.sh            # builds into ./build
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$PWD/build}"
UBOOT_REF="${UBOOT_REF:-62c9805d8d57cad407f0295879cc9a6182da464a}"   # tested commit
NURA_REF="${NURA_REF:-5b2241bb5c1bd0af2ce455a4efdabd7e8a5d9e24}"     # DTS source commit
mkdir -p "$WORK" && cd "$WORK"

# 1. U-Boot
if [ ! -d u-boot ]; then
  git init -q u-boot
  git -C u-boot remote add origin https://github.com/u-boot/u-boot.git
fi
git -C u-boot fetch -q --depth 1 origin "$UBOOT_REF"
git -C u-boot checkout -q -f FETCH_HEAD
cp "$HERE/oneplus-guacamole.config" u-boot/board/qualcomm/
# guacamole fixes (PMIC GPIO pull-ups for the volume keys, on-screen hang log)
for p in "$HERE"/../patches/*.patch; do
  git -C u-boot apply --check "$p" 2>/dev/null && git -C u-boot apply "$p" && echo "applied $(basename "$p")"
done
make -C u-boot CROSS_COMPILE=aarch64-linux-gnu- O=.output \
     qcom_defconfig qcom-phone.config oneplus-guacamole.config
make -C u-boot CROSS_COMPILE=aarch64-linux-gnu- O=.output -j"$(nproc)"
gzip -9 -n -c u-boot/.output/u-boot-nodtb.bin > u-boot-nodtb.bin.gz

# 2. Device tree (flat DTS from the guacamole_nura bring-up, + U-Boot fixups)
if [ ! -d guacamole_nura ]; then
  git clone https://github.com/emilyastranova/guacamole_nura.git
fi
git -C guacamole_nura checkout -q "$NURA_REF"
python3 -I "$HERE/make_dts.py" guacamole_nura/base_guacamole_working.dts sm8150-oneplus-guacamole-uboot.dts
dtc -q -I dts -O dtb sm8150-oneplus-guacamole-uboot.dts -o sm8150-oneplus-guacamole.dtb
# Linux-only variant with USB-C DisplayPort alt mode (systemd-boot loads it
# with a `devicetree` line; U-Boot keeps the plain one)
python3 -I "$HERE/make_dts_dp.py" sm8150-oneplus-guacamole-uboot.dts sm8150-oneplus-guacamole-dp.dts
dtc -q -I dts -O dtb sm8150-oneplus-guacamole-dp.dts -o sm8150-oneplus-guacamole-dp.dtb

# 3. Android boot image v2 (what the stock OnePlus ABL loads)
python3 -I "$HERE/mkbootimg_v2.py" u-boot-nodtb.bin.gz sm8150-oneplus-guacamole.dtb u-boot-guacamole.img

# 4. hand the results to flash-uboot.ps1 / install-arch.sh (kit's images/ folder)
IMG="$HERE/../images"; mkdir -p "$IMG"
cp u-boot-guacamole.img sm8150-oneplus-guacamole.dtb sm8150-oneplus-guacamole-dp.dtb "$IMG/"
( cd "$IMG" && sha256sum u-boot-guacamole.img sm8150-oneplus-guacamole.dtb sm8150-oneplus-guacamole-dp.dtb > SHA256SUMS && cat SHA256SUMS )
echo "Done: $IMG/u-boot-guacamole.img"
