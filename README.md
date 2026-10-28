# OnePlus 7 Pro (guacamole) – mainline Linux kit

Run **Arch Linux ARM on a mainline 6.17 kernel** on the OnePlus 7 Pro (GM1910 / GM1913 / GM1917, Snapdragon 855 / SM8150), with or without a KDE Plasma desktop.

```
stock ABL (unlocked) -> U-Boot (boot_a/boot_b) -> systemd-boot (EFI) -> Linux 6.17 (+ DisplayPort DTB)
```

The kit contains:

1. **Backup** of the partitions that can't be replaced (IMEI, calibration, MACs).
2. **U-Boot**: build it, test it from RAM, then install it.
3. **Kernel**: sm8150-mainline 6.17 with the guacamole_nura patches and this kit's fixes.
4. **Arch Linux ARM install**, with a desktop or headless.
5. **guacamole-tools**: a battery-care service, thermal limits, the *Guacamole Panel* app, a full-screen *Server Monitor* and the `guac` CLI.

> ⚠️ **This wipes Android and its user data.** Start from stock **OxygenOS 12** (see [Starting point](#starting-point-what-the-phone-should-be-running)) with the bootloader unlocked, and know how to unbrick with the **MSM Download Tool** for your model before you start. Nothing here touches `persist`, `modemst1/2`, `fsg` or `fsc`, but take the backup in step 1 anyway. You use this kit at your own risk.

> 🤖 **Made with AI assistance.** Most of the scripts, the kit's kernel patches (0101–0105) and this documentation were written with an AI assistant (Anthropic's Claude), working with the author step by step on a real phone. The author ran and checked the results on their own OnePlus 7 Pro (12 GB/256 GB), and the README says which parts are untested. AI-written code can still be wrong in ways that look plausible, so read the scripts before running them as root, especially anything that writes to the phone's storage. There is no warranty (see LICENSE). Bug reports and fixes are welcome.

## What works

| Works | Doesn't (yet) |
|---|---|
| 1440×3120 @ 90 Hz display and touch | Camera, fingerprint |
| GPU (Adreno 640, freedreno/turnip) | Calls, earpiece, mobile data (untested) |
| Wi-Fi 2.4/5 GHz, Bluetooth | DisplayPort audio |
| USB host and gadget (SSH over the cable) | Haptics, alert slider, flash LED |
| USB-C DisplayPort alt mode (up to 3440×1440 @ 60 Hz, 2 lanes) | RTC (the clock comes from NTP) |
| Speakers and microphone | |
| Charging, battery-care limit (battery held idle on the charger) | |
| Sensors: accelerometer (auto-rotate), light, proximity | |

**Known issues**
- **Occasional black-screen hang right after the boot menu.** A long press on power recovers it.
- **Speakers are quiet,** and there's no speaker protection. Keep the volume reasonable.
- **The UFS link is capped at HS-G3.** At HS-G4 it silently corrupts writes. **Never boot a distro's own kernel:** only kernels built with `build-kernel.sh` have the cap.

## Starting point: what the phone should be running

Start from **stock OxygenOS 12** (Android 12), updated to the **last official release** (December 2022 security patch). This kit was tested with that, and the order matters:

1. **Get onto OxygenOS 12.** Update stock OxygenOS to the final OxygenOS 12 build through the normal system updater.
   - If the phone runs a custom ROM, or is in an unknown state, restore it with the **MSM Download Tool** for your model first, then update with OTAs up to the last OxygenOS 12.
2. **Unlock the bootloader.** Enable *OEM unlocking* in Developer options, then run `fastboot oem unlock`. This wipes Android.
   - If `fastboot oem unlock` fails "for technical reason", MSM-restore and try again.
3. **Boot OxygenOS once** after the unlock. Skip the setup, but let it reach the home screen.
4. **Continue with step 1 below** (backup) while Android is still intact.

Why this matters:

- **Your Android version stays in charge of booting.** U-Boot replaces only the `boot` partitions. The bootloader (ABL, XBL) and the firmware partitions stay whatever your Android version installed. U-Boot and the boot images here were tested on OxygenOS 12's bootloader. The other slot held OxygenOS 11, so firmware from either version is fine, but older ones (OxygenOS 10) haven't been tried.
- **You don't install the LineageOS zip.** `build-firmware.sh` only reads Wi-Fi and Bluetooth firmware out of it. Download it; don't flash it.
- **Models:** tested on the global/EU model (GM1913, GM1910 hardware).
  - **GM1917** (US unlocked) uses the same hardware.
  - **GM1915** (T-Mobile) must be converted to the global firmware with the MSM tool and unlocked first.
  - The **5G model (GM1920)** is different hardware and **won't work**.
- **Memory and storage:** the 6 GB/128 GB, 8 GB/256 GB and 12 GB/256 GB versions are all supported. The bootloader tells Linux how much RAM there is, and the installer sizes the Linux partition to the storage. Only 12 GB/256 GB has been tested on a real phone.

## What you need

- **The phone:** on OxygenOS 12 as above, bootloader unlocked, charged.
- **A Windows PC:**
  - [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) (`adb`, `fastboot`) and the Google USB driver.
  - **WSL2** with Ubuntu, plus `usbipd`. In an admin PowerShell, run `wsl --install -d Ubuntu`, then `winget install usbipd`.
  - A Linux PC works instead of Windows + WSL. Run the `.sh` scripts the same way, and use your own tools in place of the `.ps1` scripts.
- **A LineageOS zip for guacamole:** `build-firmware.sh` takes the Wi-Fi, Bluetooth and DSP firmware from it. You only download it; you don't install it.
  - **Where:** get the current build from [download.lineageos.org/devices/guacamole/builds](https://download.lineageos.org/devices/guacamole/builds). The file is called `lineage-<version>-<date>-nightly-guacamole-signed.zip`, about 1.2 GB. Older builds are removed after a while.
  - **Tested with:** an October 2026 build (Android 17, security patch 2026-10-01). Its vendor firmware comes from OxygenOS 12. Newer builds should work too, since only these firmware files are used.
- **TWRP for guacamole,** for the backup in step 1: [twrp.me/oneplus/oneplus7pro.html](https://twrp.me/oneplus/oneplus7pro.html) (download `twrp-<version>-guacamole.img`). It's only booted from RAM, never installed.
- **Build tools** (a Linux PC with Ubuntu/Debian, or Ubuntu in WSL):

```bash
sudo apt update && sudo apt install build-essential gcc-aarch64-linux-gnu device-tree-compiler flex bison \
  libssl-dev libgnutls28-dev uuid-dev python3-pyelftools swig bc xxd git curl clang lld llvm libelf-dev \
  cpio kmod gdisk dosfstools e2fsprogs parted libarchive-tools mtools python3
```

**Where to keep the kit.** Use one copy, inside Linux (building on `/mnt/c` is very slow):

```bash
cd ~ && git clone https://github.com/jboptical/guacamole-linux-kit.git && cd guacamole-linux-kit
```

Run the `.sh` scripts there, from the kit folder:

```bash
bash scripts/<name>.sh
```

Windows reaches the same folder as `\\wsl.localhost\Ubuntu\home\<your user>\guacamole-linux-kit`. That way the `.ps1` scripts find the images the build wrote, and the backup lands next to the kit. Open PowerShell there and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\<name>.ps1 ...
```

**Key combos**
- **Fastboot:** with the phone off, hold Vol Up + Vol Down + Power.
- **U-Boot menu:** hold Vol Down while it starts. Vol Up/Down move, Power selects (the same in systemd-boot).
- **Forced reboot:** hold Power + Vol Up for about 15 s.

---

## 1. Back up the irreplaceable partitions

`persist`, `modemst1/2`, `fsg` and `fsc` hold your IMEI, radio and sensor calibration, and MAC addresses. No update can bring them back.

1. Boot TWRP for guacamole (see *What you need*) from RAM, with the phone in fastboot: `fastboot boot twrp-<version>-guacamole.img`.
2. Run the backup:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\backup-partitions.ps1
   ```
   On Linux, use `scripts/backup-partitions.sh` instead.
3. Check that the five critical images exist and aren't empty.
4. Keep **two copies off the phone**, somewhere private. The images contain your IMEI.

The backup also includes `boot`, `dtbo`, `vbmeta`, `modem`, `dsp` and `bluetooth` for both slots, which is everything you need to go back to Android.

## 2. Build and install U-Boot

**Build it** (Linux or WSL):

```bash
bash scripts/build-uboot.sh
```

This writes `images/u-boot-guacamole.img`, the U-Boot DTB, the Linux DisplayPort DTB and `SHA256SUMS`.

**Test it from RAM first** (PowerShell, phone in fastboot). This uses the **inactive** slot, so Android still boots:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\flash-uboot.ps1 -Mode Test
```

You should see U-Boot's text console and boot menu, and the volume keys should work. To go back to Android: `flash-uboot.ps1 -Mode Restore -Slot <your Android slot>`.

**Install it on both slots.** Android stops booting from here:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\flash-uboot.ps1 -Mode Install
```

If you ever see "the current image has been destroyed", run `fastboot --set-active=a`. The installed system marks its slot as successful at every boot (`ab-mark-successful.service`), so this shouldn't happen again.

## 3. Build the kernel and the firmware (Linux or WSL)

```bash
bash scripts/build-kernel.sh                                        # 20-40 min -> build/guacamole-kernel-<release>.tar.gz
bash scripts/build-firmware.sh ~/lineage-*-guacamole-signed.zip     # the zip you downloaded -> build/guacamole-firmware.tar.gz
```

**The kernel** is sm8150-mainline `v6.17.0-sm8150` (hash-checked), plus guacamole_nura's 24 patches, plus this kit's patches in `patches-kernel/`:

| Patch | What it does |
|---|---|
| 0101 | DisplayPort bandwidth check: no more hangs on high-resolution monitors |
| 0102 | Fixes memory corruption when freeing imported GPU buffers |
| 0103 | Waits for the panel to be idle before sending commands |
| 0104 | Turns off the bootloader's display autorefresh before the IOMMU attaches |
| 0105 | Charge inhibit (`charge_behaviour`), so the battery can sit idle on the charger |

**The firmware** comes from OxygenOS 11 (modem, DSPs, GPU zap shader) and LineageOS (WLAN, Bluetooth). It's proprietary, so it isn't part of this repo.

## 4. Partition the phone and install Arch

1. **Put the phone in mass-storage mode.** Boot to U-Boot, hold Vol Down, and choose **Enable USB mass storage**.
   **When Windows offers to format or initialise the disk, click Cancel. Never accept.**
2. **Connect the disk.**
   - **WSL:** attach it from an admin PowerShell:
     ```powershell
     powershell -ExecutionPolicy Bypass -File .\scripts\wsl-attach-phone.ps1
     ```
   - **Linux PC:** it simply appears.
3. **Install** (Linux or WSL). Pick one:
   ```bash
   sudo bash scripts/install-arch.sh --partition --gui        # KDE Plasma desktop
   sudo bash scripts/install-arch.sh --partition --headless   # no desktop (server)
   ```
   - **Finding the disk:** the installer finds the phone's disk by itself: the only disk with 4096-byte sectors and a `persist` partition. It shows the disk's name, size and model, and waits for you to type `y`. If it finds none, or more than one, it stops.
   - **Checking by hand:** run `lsblk -d -o NAME,SIZE,LOG-SEC,MODEL`. The phone is the line with `LOG-SEC 4096`, about **234G** on the 256 GB model (about **117G** on the 128 GB model; estimated, not seen yet). Then pass it with `--disk /dev/sdX`.
   - **`--partition`** is only for the first install. It splits `userdata` into a 4 GiB placeholder, a 1 GiB ESP and `linux1` (the rest), after asking you to type `ERASE-USERDATA`. To reinstall later, leave it out.
4. **Release the disk and reboot the phone.**
   - **WSL:** detach it with `.\scripts\wsl-attach-phone.ps1 -Detach`.
   - **Linux PC:** run `sync`.

`partition-ufs.sh` refuses any disk that isn't the phone's LUN0, and saves a GPT backup (`gpt-lun0-backup-*.sgdisk`) before changing anything. Keep that file.

## 5. First boot: set up the phone

The phone boots to Arch and appears on the PC as a USB network adapter. The PC gets an address from the phone automatically.

Wi-Fi doesn't work yet (its firmware and modem services aren't installed), so lend the phone the PC's internet over SSH:

```powershell
ssh -R 1080 alarm@10.66.0.1        # password: alarm
```

Then, in that session:

```bash
su                                  # password: root
bash /home/alarm/guacamole-kit/scripts/setup-arch.sh     # --gui / --headless as chosen at install
systemctl reboot
```

`setup-arch.sh` runs, in order:

1. `setup-qcom.sh`: firmware, rmtfs/tqftpserv/qrtr, modem for Wi-Fi.
2. `setup-network.sh`: NetworkManager, with Wi-Fi power save off.
3. `personalize-dtb.sh`: the phone's own Wi-Fi/Bluetooth MAC addresses in the DTB.
4. `setup-audio.sh`.
5. `setup-chrony.sh`: NTP time sync. There is no RTC.
6. `setup-sensors.sh`: sensors.
7. `setup-desktop-arch.sh` (Plasma, SDDM, on-screen keyboard), for `--gui` only.
8. guacamole-tools.

Options: `--no-sensors`, `--no-tools`, `--regdom US` (your Wi-Fi country). The log goes to `/root/guacamole-setup.log`.

**After the reboot:**

```bash
nmcli device wifi connect "<SSID>" --ask      # or use the network icon in Plasma
passwd alarm; passwd root                     # change the default passwords
```

## 6. guacamole-tools

| Tool | What it does |
|---|---|
| **guacamole-chgctrl** (service) | Sets the charger input limit from the USB-PD contract or charger type. Throttles charging above 42 °C and stops it at 45 °C. Adds a battery-care window: by default it charges to 80 %, then holds with charging inhibited (the battery sits idle and the charger runs the phone), and charges again below 75 %. Phone power draw is measured on battery, or estimated from the charger's sensor with a calibration every 4 h. Config: `/etc/guacamole/chgctrl.conf`. |
| **guacamole-thermal** (service) | Throttles the CPUs from 80 °C (harder at 85 °C) and the GPU from 80 °C. Mainline's defaults are 90/95/85. Config: `/etc/guacamole/thermal.conf`. |
| **Guacamole Panel** (app) | Battery, charger and battery-care controls; temperatures; CPU, GPU and memory; Ethernet, Wi-Fi, Bluetooth, USB-C/DP and PD contract; brightness; swap file; "keep awake" server mode. |
| **Server Monitor** (app) | Full-screen dark status page for a phone used as a server, opened at login while server mode is on. It drifts slightly every minute to protect the AMOLED screen. |
| **`guac`** (CLI) | The panel in a terminal: `guac`, `guac battery`, `guac net`, `guac watch`, `guac charge 60 58 58 0`, `guac no-suspend on`, `guac swap 4`, `guac governor performance`, `guac brightness 40`. |

On a headless install, only the services and `guac` are installed. To install them by hand: `sh guacamole-tools/install-guacamole-tools.sh`, with `HEADLESS=1` for the headless set.

## Updating the kernel later

1. Build with a new suffix, so the new kernel installs next to the working one:
   ```bash
   KSUFFIX=-guac2 bash scripts/build-kernel.sh
   ```
2. Copy the package to the phone, then as root:
   ```bash
   sh scripts/update-kernel.sh guacamole-kernel-6.17.0-sm8150-guac2.tar.gz
   ```
3. Pick the new entry in the boot menu.
4. Once it works, make it the default: edit `default` in `/efi/loader/loader.conf`.

## Layout

| Path | Contents |
|---|---|
| `scripts/` | Everything you run. `.ps1` files run on Windows; `install-arch.sh`, `partition-ufs.sh`, `install-distro.sh` and the `build-*` scripts run on the PC (WSL); `setup-*`, `personalize-dtb.sh`, `update-kernel.sh` and `power-sample.sh` run on the phone |
| `patches/` | U-Boot patches: PMIC GPIO pulls for the volume keys, on-screen hang log, dwc3 UTMI clock |
| `patches-kernel/` | Kernel patches 0101–0105 |
| `src/` | The U-Boot DTS and the pinned commits |
| `sensors/` | Sensor stack: hexagonrpcd patches, udev rules, registry import |
| `guacamole-tools/` | Battery care, thermal limits, Panel, Server Monitor, `guac` |
| `images/` | Build output of `build-uboot.sh` (not in git) |

## Test status

**In daily use on the author's phone** (12 GB/256 GB, OxygenOS 12 base):
- The U-Boot image, the kernel with patches 0101–0105 and the firmware set.
- Every individual setup script (`setup-qcom`, `personalize-dtb`, `setup-audio`, `setup-chrony`, `setup-sensors`, `setup-desktop-arch`, lightly adapted for the kit) and guacamole-tools. The author's install was done step by step with these scripts, from Arch Linux ARM with Plasma.

**Tested off the phone:**
- `install-arch.sh` (with `--partition`, `--gui` and `--headless`) and `partition-ufs.sh`, run in WSL against sparse disks the size of both models laid out like the phone's. This covered partitioning, the rootfs, kernel, boot entry, device tree and kit copy.

**Not yet run on a fresh phone:**
- The all-in-one `setup-arch.sh` and the new `setup-network.sh`. They run the scripts above in order, plus the internet-through-the-PC bootstrap.
- `build-uboot.sh`'s DisplayPort DTB step.
- The headless guacamole-tools install.
- The 6 GB/128 GB and 8 GB/256 GB models.

If you try any of these, please report how it went.

## Credits

- **[guacamole_nura](https://github.com/emilyastranova/guacamole_nura)** (Emily Astranova): the device tree, kernel patches, firmware extraction, sensor recipe and the charger daemon that guacamole-chgctrl is based on.
- **[sm8150-mainline](https://gitlab.com/sm8150-mainline/linux):** the kernel.
- **U-Boot's Qualcomm phone support:** Casey Connolly et al.
- **[M1DNYT3/firmware-oneplus-guacamole](https://github.com/M1DNYT3/firmware-oneplus-guacamole):** the firmware set.
- **[linux-msm](https://github.com/linux-msm):** qrtr, rmtfs, tqftpserv, hexagonrpc.
- **postmarketOS** and the nethunter-pro-guacamole notes.

## Licence

- **Scripts and guacamole-tools:** GPL-3.0. guacamole-chgctrl is derived from guacamole_nura's GPL-3.0 charger daemon.
- **Kernel and U-Boot patches:** GPL-2.0, like the projects they patch.
- **Firmware:** proprietary, not included. You build it from your own OTA download.
