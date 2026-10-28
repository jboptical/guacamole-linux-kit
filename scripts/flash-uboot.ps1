<#
  Test or install U-Boot on the OnePlus 7 Pro from Windows (phone in fastboot mode:
  power off, then hold Vol Up + Vol Down + Power).

    # Step 2: RAM test on the INACTIVE slot (Android on the current slot is untouched)
    powershell -ExecutionPolicy Bypass -File .\scripts\flash-uboot.ps1 -Mode Test
    # Re-test (e.g. a diagnostic image). The Android slot is remembered in
    # android-slot.txt next to the images; -Slot forces the TEST slot.
    powershell -ExecutionPolicy Bypass -File .\scripts\flash-uboot.ps1 -Mode Test -Slot a -Image .\images\u-boot-guacamole-diag.img

    # Go back to Android after the test
    powershell -ExecutionPolicy Bypass -File .\scripts\flash-uboot.ps1 -Mode Restore -Slot a

    # Step 3: flash U-Boot to BOTH slots (Android will no longer boot)
    powershell -ExecutionPolicy Bypass -File .\scripts\flash-uboot.ps1 -Mode Install
#>
param(
    [Parameter(Mandatory)][ValidateSet('Test','Install','Restore')][string]$Mode,
    [ValidateSet('a','b')][string]$Slot,
    [string]$Image = (Join-Path $PSScriptRoot '..\images\u-boot-guacamole.img')
)
$ErrorActionPreference = 'Stop'

function FB { param([Parameter(ValueFromRemainingArguments)]$a)
    Write-Host "> fastboot $($a -join ' ')" -ForegroundColor Cyan
    & fastboot @a
    if ($LASTEXITCODE -ne 0) { throw "fastboot $($a -join ' ') failed" }
}
function Get-Var([string]$name) {
    # fastboot prints getvar results on stderr
    $ErrorActionPreference = 'Continue'
    $o = (& fastboot getvar $name 2>&1 | Out-String)
    if ($o -match "${name}:\s*(\S+)") { return $Matches[1] } else { return "" }
}

if (-not (Get-Command fastboot -ErrorAction SilentlyContinue)) { throw "fastboot not found (install Android platform-tools)." }
if ($Mode -ne 'Restore') {
    if (-not (Test-Path $Image)) {
        # allow paths relative to the kit folder when run from scripts\
        $alt = Join-Path (Join-Path $PSScriptRoot '..') $Image
        if (Test-Path $alt) { $Image = $alt } else { throw "Image not found: $Image" }
    }
    $Image = (Resolve-Path $Image).Path
    Write-Host "Image: $Image"
    $sums = Join-Path (Split-Path $Image) 'SHA256SUMS'
    if (Test-Path $sums) {
        $leaf = Split-Path $Image -Leaf
        $entry = Get-Content $sums | Where-Object { ($_ -split '\s+')[-1] -eq $leaf } | Select-Object -First 1
        if ($entry) {
            $want = ($entry -split '\s+')[0]
            $have = (Get-FileHash $Image -Algorithm SHA256).Hash.ToLower()
            if ($want -ne $have) { throw "Checksum mismatch for $Image" }
            Write-Host "Checksum OK ($leaf)"
        } else { Write-Warning "No checksum listed for $leaf" }
    }
}

Write-Host "Waiting for fastboot device..."
$devs = (& fastboot devices 2>$null | Out-String).Trim()
if (-not $devs) { throw "No fastboot device. Boot the phone into fastboot (Vol Up + Vol Down + Power) and check the USB driver." }
Write-Host $devs

$product = Get-Var 'product'
if ($product -and $product -notmatch 'msmnile|guacamole|OnePlus7Pro') {
    Write-Warning "fastboot reports product '$product' - expected msmnile/guacamole."
    if ((Read-Host "Continue anyway? (y/N)") -ne 'y') { exit 1 }
}
$cur = Get-Var 'current-slot'
Write-Host "Current slot: $cur"

switch ($Mode) {
  'Test' {
    if ($cur -notin 'a','b') { throw "Could not read current slot." }
    $stateFile = Join-Path (Split-Path $Image) 'android-slot.txt'
    $android = if (Test-Path $stateFile) { (Get-Content $stateFile | Select-Object -First 1).Trim() } else { $null }
    if (-not $android) {
        if ($Slot) { $android = if ($Slot -eq 'a') { 'b' } else { 'a' } } else { $android = $cur }
        Set-Content -Path $stateFile -Value $android
        Write-Host "Recorded Android slot '$android' in $stateFile"
    }
    $test = if ($Slot) { $Slot } elseif ($android -eq 'a') { 'b' } else { 'a' }
    if ($test -eq $android) { throw "Refusing: slot '$test' is the Android slot (see $stateFile)." }
    Write-Host "Android slot: '$android' (not modified). Test slot: '$test'." -ForegroundColor Yellow
    FB erase "dtbo_$test"
    FB "--set-active=$test"
    Write-Host "If this hangs at 'Sending', unplug/replug the cable and run the script again."
    # The OnePlus ABL often answers 'Load Error' on fastboot boot; restarting the
    # bootloader and retrying clears it.
    $booted = $false
    for ($try = 1; $try -le 4 -and -not $booted; $try++) {
        Write-Host "> fastboot boot $Image   (attempt $try)" -ForegroundColor Cyan
        $ErrorActionPreference = 'Continue'
        & fastboot boot $Image
        $ok = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = 'Stop'
        if ($ok) { $booted = $true; break }
        Write-Warning "Boot attempt $try failed; restarting the bootloader and retrying..."
        $ErrorActionPreference = 'Continue'
        & fastboot reboot bootloader 2>$null | Out-Null
        $back = $false
        for ($w = 0; $w -lt 20; $w++) {
            Start-Sleep -Seconds 2
            if ((& fastboot devices 2>$null | Out-String).Trim()) { $back = $true; break }
        }
        $ErrorActionPreference = 'Stop'
        if (-not $back) { throw "Phone didn't come back to fastboot. Hold Vol Up + Vol Down + Power, then run the script again." }
        Start-Sleep -Seconds 2
    }
    if (-not $booted) { throw "fastboot boot kept failing. Unplug/replug the cable, reboot to fastboot by hand and try again." }
    Write-Host ""
    Write-Host "Watch the phone. To return to Android afterwards:"
    Write-Host "  .\scripts\flash-uboot.ps1 -Mode Restore -Slot $android"
  }
  'Restore' {
    if (-not $Slot) { throw "Pass -Slot a or -Slot b (the slot Android was on)." }
    FB "--set-active=$Slot"
    FB reboot
  }
  'Install' {
    Write-Host "This flashes U-Boot to boot_a AND boot_b and erases dtbo_a/dtbo_b." -ForegroundColor Red
    Write-Host "Android will no longer boot. Make sure the backup (Step 1) is done and copied off the phone." -ForegroundColor Red
    if ((Read-Host "Type INSTALL to continue") -ne 'INSTALL') { Write-Host "Aborted."; exit 1 }
    FB flash boot_a $Image
    FB flash boot_b $Image
    FB erase dtbo_a
    FB erase dtbo_b
    FB "--set-active=a"
    FB reboot
    Write-Host "Done. Hold Vol Down while it starts to get the U-Boot menu."
  }
}
