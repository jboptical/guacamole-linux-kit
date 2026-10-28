<#
  Hand the phone's U-Boot "USB mass storage" disk to WSL2 so the Linux scripts
  (partition-ufs.sh, install-distro.sh) can reach it.

  One-time setup (admin PowerShell):
    wsl --install -d Ubuntu          # reboot if asked, create a user
    winget install usbipd            # https://github.com/dorssel/usbipd-win

  Each time (phone showing the U-Boot menu -> "Enable USB mass storage"):
    # ADMIN PowerShell, from the kit folder
    powershell -ExecutionPolicy Bypass -File .\scripts\wsl-attach-phone.ps1
    # when finished:
    powershell -ExecutionPolicy Bypass -File .\scripts\wsl-attach-phone.ps1 -Detach

  If Windows pops up "You need to format the disk" -> click CANCEL. Never format it.
#>
param([switch]$Detach)
$ErrorActionPreference = 'Stop'
$VidPid = '18d1:4ee0'   # U-Boot gadget IDs (CONFIG_USB_GADGET_VENDOR_NUM/PRODUCT_NUM)

function Get-PhoneLine {
    (& usbipd list) | Where-Object { $_ -match "^\s*(\d+-\d+)\s+$VidPid" } | Select-Object -First 1
}

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) { throw "usbipd not found. Run: winget install usbipd  (then open a new admin PowerShell)" }
if (-not (Get-Command wsl -ErrorAction SilentlyContinue))    { throw "WSL not installed. Run: wsl --install -d Ubuntu" }

function Wait-Phone([string]$msg) {
    Write-Host ""
    Write-Host ">>> $msg" -ForegroundColor Yellow
    for ($i = 0; $i -lt 90; $i++) {
        $l = Get-PhoneLine
        if ($l) { return $l }
        Start-Sleep -Seconds 2
    }
    throw "Phone not seen. Check the cable and that the phone shows 'Press any key to exit UMS mode'."
}

$line = Get-PhoneLine
if (-not $line) {
    $line = Wait-Phone "On the phone: hold Vol Down at boot (or press it at 'Press any key') -> 'Enable USB mass storage'. Waiting..."
}
$busid = ($line -split '\s+' | Where-Object { $_ })[0]
Write-Host "Phone found on bus $busid"
Write-Host "  $($line.Trim())"

if ($Detach) {
    & usbipd detach --busid $busid
    Write-Host "Detached. Press a key on the phone to leave mass-storage mode."
    exit 0
}

if ($line -notmatch 'Attached') {
    # Some usbipd versions show a forced bind as plain "Shared"; only bind when needed.
    if ($line -match 'Not shared') {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin) { throw "Binding needs an ADMIN PowerShell." }
        # --force keeps Windows' own disk driver off the phone (otherwise usbipd
        # reports "Device in error state"). Windows releasing the device looks like
        # a disconnect, so U-Boot leaves UMS mode; the binding is remembered.
        & usbipd bind --busid $busid --force
        Start-Sleep -Seconds 3
        $line = Get-PhoneLine
        if (-not $line) {
            $line = Wait-Phone "The phone left USB mass storage (expected). Select 'Enable USB mass storage' on the phone again. Waiting..."
        }
        $busid = ($line -split '\s+' | Where-Object { $_ })[0]
        Write-Host "  $($line.Trim())"
    }
    # make sure a WSL distro is running so attach has a target
    & wsl --exec true
    Write-Host "Attaching to WSL (auto-attach runs in a separate window; leave it open)..."
    Start-Process -FilePath usbipd -ArgumentList @('attach', '--wsl', '--busid', $busid, '--auto-attach')
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        if ((Get-PhoneLine) -match 'Attached') { break }
    }
    if ((Get-PhoneLine) -notmatch 'Attached') {
        Write-Warning "Not attached yet. If the phone dropped out of UMS mode, re-enter it; auto-attach will pick it up."
    }
    Start-Sleep -Seconds 3
}

Write-Host "Disks seen by WSL:"
& wsl --exec lsblk -o NAME,SIZE,LOG-SEC,PARTLABEL
Write-Host ""
Write-Host "The phone is the ~234G disk with LOG-SEC 4096 and partitions like 'persist' and 'userdata'."
Write-Host "If no such disk appears, use a live Ubuntu USB stick instead (WSL kernel without usb-storage)."
