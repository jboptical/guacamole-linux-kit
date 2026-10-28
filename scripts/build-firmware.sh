#!/usr/bin/env bash
# Assemble the OnePlus 7 Pro device firmware set (run in WSL / Linux).
# Same choice of files as guacamole_nura's firmware-oneplus-guacamole package,
# which is verified on hardware:
#   - OxygenOS 11 MPSS modem, SLPI, ADSP/CDSP, GPU zap shader
#       (M1DNYT3/firmware-oneplus-guacamole; the OOS12 modem is too big for the
#        reserved mpss region)
#   - Android-12-era WLAN firmware (wlanmdsp.mbn), WCN3990 board data, Bluetooth
#     rampatch/NVM, IPA firmware and SLPI PD maps from a LineageOS guacamole OTA
#       (the OOS10/11 WLAN firmware refuses to connect under mainline ath10k)
# Generic files (ath10k firmware-5.bin, Adreno a630_sqe/a640_gmu) come from the
# distro's linux-firmware packages, installed by setup-qcom.sh.
#
#   sudo apt install mtools e2fsprogs git python3
#   bash scripts/build-firmware.sh ~/Downloads/lineage-*-guacamole-signed.zip
#   -> build/guacamole-firmware.tar.gz  (extract on the phone with: tar -xzf ... -C /)
set -euo pipefail
OTA="${1:?usage: $0 <lineage-*-guacamole-signed.zip>}"
[ -f "$OTA" ] || { echo "no such file: $OTA"; exit 1; }
for t in mcopy debugfs git python3; do command -v $t >/dev/null || { echo "missing $t (sudo apt install mtools e2fsprogs git python3)"; exit 1; }; done
WORK="${WORK:-$PWD/build}"
NURA_REF="${NURA_REF:-5b2241bb5c1bd0af2ce455a4efdabd7e8a5d9e24}"
FW_REF="${FW_REF:-f071a51faf6f6250c35662e8091deb2cb484a025}"
mkdir -p "$WORK" && cd "$WORK"

# 1. sources
[ -d guacamole_nura ] || git clone https://github.com/emilyastranova/guacamole_nura.git
git -C guacamole_nura checkout -q "$NURA_REF"
[ -d fw-oos11 ] || git clone https://github.com/M1DNYT3/firmware-oneplus-guacamole.git fw-oos11
git -C fw-oos11 checkout -q "$FW_REF"

# 2. LineageOS OTA -> WLAN/BT/IPA/board set
rm -rf losfw && mkdir losfw
python3 guacamole_nura/scripts/extract_lineage_firmware.py "$OTA" "$WORK/losfw"
LOS_TAR=$(ls losfw/firmware-oneplus-guacamole-*.tar.gz)
mkdir losfw/x && tar -xzf "$LOS_TAR" -C losfw/x
LOS=$(echo losfw/x/firmware-oneplus-guacamole-*)
cat losfw/*.VERSIONS

# 3. assemble the root tree
R="$WORK/fwroot"; rm -rf "$R"
F="$R/usr/lib/firmware"
DEV="$F/qcom/sm8150/oneplus7"
mkdir -p "$DEV" "$F/qcom" "$F/updates/ath10k/WCN3990/hw1.0" "$F/updates/qca"

# OOS11: GPU zap shader (split ELF), modem, SLPI, ADSP, CDSP, WLAN PD map
cp fw-oos11/qcom/a640_zap.mdt fw-oos11/qcom/a640_zap.b0[0-9] "$F/qcom/"
for f in fw-oos11/qcom/sm8150/oneplus7/{modem,slpi,adsp,cdsp}.{mdt,b[0-9][0-9]} fw-oos11/qcom/sm8150/oneplus7/modemuw.jsn; do
  [ -e "$f" ] && cp "$f" "$DEV/"
done
# LineageOS (Android 12 era): WLAN firmware, SLPI PD maps, IPA firmware
cp "$LOS/qcom/sm8150/oneplus7/wlanmdsp.mbn" "$DEV/"
cp "$LOS"/qcom/sm8150/oneplus7/slpi*.jsn "$DEV/" 2>/dev/null || true
cp "$LOS/qcom/sm8150/oneplus7/ipa_fws.mbn" "$DEV/"
# Files that clash with linux-firmware package paths go to updates/ (searched first)
cp "$LOS/ath10k/WCN3990/hw1.0/board-2.bin" "$F/updates/ath10k/WCN3990/hw1.0/"
cp "$LOS"/qca/crbtfw21.tlv "$LOS"/qca/crnv21.bin "$F/updates/qca/"

# sanity checks
for f in "$DEV/modem.mdt" "$DEV/wlanmdsp.mbn" "$DEV/ipa_fws.mbn" "$DEV/slpi.mdt" "$F/qcom/a640_zap.mdt" \
         "$F/updates/ath10k/WCN3990/hw1.0/board-2.bin" "$F/updates/qca/crnv21.bin"; do
  [ -s "$f" ] || { echo "MISSING: $f"; exit 1; }
done
find "$R" -type f | sed "s|$R||" | sort > guacamole-firmware.list
tar -C "$R" --owner=0 --group=0 -czf guacamole-firmware.tar.gz usr
echo
echo "$(wc -l < guacamole-firmware.list) files -> $WORK/guacamole-firmware.tar.gz"
echo "Copy to the phone:  scp build/guacamole-firmware.tar.gz alarm@10.66.0.1:/tmp/"
