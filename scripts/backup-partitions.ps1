<#
  Back up every small partition (persist, EFS/IMEI, modem, dsp, bluetooth,
  dtbo, vbmeta, boot, ABL/XBL ...) plus the GPT of every UFS LUN.

  Needs a ROOT adb shell on the phone: TWRP or LineageOS recovery booted with
  `fastboot boot <recovery>.img`, or rooted Android (Magisk).

  Run from the kit folder:
    powershell -ExecutionPolicy Bypass -File .\scripts\backup-partitions.ps1

  Result: .\guacamole-backup-<date>\  -- keep it PRIVATE (contains IMEI/keys)
  and keep 2 copies off the phone. Partitions > 512 MiB (system, vendor,
  userdata...) are skipped; they can be restored from an OxygenOS OTA.
#>
$ErrorActionPreference = 'Stop'
$Max = 512MB
$Out = Join-Path (Get-Location) ("guacamole-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $Out | Out-Null

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw "adb not found. Install Android platform-tools and add it to PATH (or run this from the platform-tools folder)."
}

# Run a shell command on the phone and return trimmed text
function Invoke-Phone([string]$cmd) {
    $ErrorActionPreference = 'Continue'   # Windows PowerShell treats native stderr as errors
    $o = & adb shell $cmd 2>$null
    if ($null -eq $o) { return "" }
    return (($o | Out-String).Trim())
}

Write-Host "Waiting for device (up to 60 s)..."
$state = ""
for ($i = 0; $i -lt 30; $i++) {
    $ErrorActionPreference = 'Continue'
    $state = ((& adb get-state 2>$null) | Out-String).Trim()
    $ErrorActionPreference = 'Stop'
    if ($state -in 'device','recovery') { break }
    Start-Sleep -Seconds 2
}
if ($state -notin 'device','recovery') {
    $ErrorActionPreference = 'Continue'
    & adb devices
    Write-Host ""
    Write-Host "adb can't see the phone. Check:" -ForegroundColor Yellow
    Write-Host "  1. The phone is showing TWRP (run: fastboot boot twrp.img)."
    Write-Host "  2. 'adb devices' lists it. If it says 'unauthorized', allow the prompt on the phone."
    Write-Host "  3. If nothing is listed: Device Manager -> the phone (yellow icon) -> Update driver ->"
    Write-Host "     Browse my computer -> Let me pick -> Android Device -> 'Android ADB Interface'"
    Write-Host "     (needs the Google USB Driver installed)."
    exit 1
}
Write-Host "Connected ($state)."

$script:UseSu = $false
if ((Invoke-Phone 'id -u') -ne '0') {
    if ((Invoke-Phone "su -c 'id -u'") -eq '0') { $script:UseSu = $true }
    else { throw "Need a root adb shell (TWRP / Lineage recovery / Magisk)." }
}
function Invoke-Root([string]$cmd) {
    if ($script:UseSu) { return Invoke-Phone "su -c '$cmd'" } else { return Invoke-Phone $cmd }
}

$Tmp = (Invoke-Phone '[ -d /tmp ] && [ -w /tmp ] && echo /tmp || echo /data/local/tmp') + '/gbak'
Invoke-Root "rm -rf $Tmp; mkdir -p $Tmp" | Out-Null

$ByName = Invoke-Phone 'ls -d /dev/block/bootdevice/by-name 2>/dev/null || ls -d /dev/block/by-name'
if (-not $ByName) { throw "Could not find /dev/block/by-name on the phone." }
Invoke-Root "ls -l $ByName" | Set-Content -Path (Join-Path $Out 'by-name-listing.txt')

$parts = (Invoke-Root "ls $ByName") -split '\s+' | Where-Object { $_ }
foreach ($p in $parts) {
    $szText = Invoke-Root "blockdev --getsize64 $ByName/$p"
    [long]$sz = 0
    if (-not [long]::TryParse($szText, [ref]$sz) -or $sz -gt $Max) {
        Write-Host "skip $p ($szText bytes)"; continue
    }
    Write-Host "dump $p ($sz bytes)"
    Invoke-Root "dd if=$ByName/$p of=$Tmp/$p.img bs=1M 2>/dev/null" | Out-Null
    & adb pull "$Tmp/$p.img" (Join-Path $Out "$p.img") | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "pull failed for $p" }
    Invoke-Root "rm -f $Tmp/$p.img" | Out-Null
}

# GPT headers (first 24 KiB / last 20 KiB on 4K-sector UFS) of each LUN
$lunInfo = @()
foreach ($lun in 'sda','sdb','sdc','sdd','sde','sdf') {
    if ((Invoke-Root "[ -b /dev/block/$lun ] && echo y") -ne 'y') { continue }
    [long]$sz = Invoke-Root "blockdev --getsize64 /dev/block/$lun"
    $last = [long]($sz / 4096) - 5
    Invoke-Root "dd if=/dev/block/$lun of=$Tmp/gpt-$lun-primary.bin bs=4096 count=6 2>/dev/null" | Out-Null
    Invoke-Root "dd if=/dev/block/$lun of=$Tmp/gpt-$lun-backup.bin bs=4096 skip=$last count=5 2>/dev/null" | Out-Null
    & adb pull "$Tmp/gpt-$lun-primary.bin" (Join-Path $Out "gpt-$lun-primary.bin") | Out-Null
    & adb pull "$Tmp/gpt-$lun-backup.bin"  (Join-Path $Out "gpt-$lun-backup.bin")  | Out-Null
    $lunInfo += "$lun $sz"
}
$lunInfo | Set-Content -Path (Join-Path $Out 'lun-sizes.txt')
Invoke-Root "rm -rf $Tmp" | Out-Null

# Checksums
Get-ChildItem $Out -File | Where-Object Name -ne 'SHA256SUMS' | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
} | Set-Content -Path (Join-Path $Out 'SHA256SUMS')

$total = (Get-ChildItem $Out -File | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Backup complete: {0}  ({1:N0} MB)" -f $Out, $total)
$must = 'persist','modemst1','modemst2','fsg','fsc'
foreach ($m in $must) {
    $f = Join-Path $Out "$m.img"
    if (-not (Test-Path $f) -or (Get-Item $f).Length -eq 0) { Write-Warning "MISSING or empty: $m.img  -- do not continue until this is fixed!" }
    else { Write-Host "OK  $m.img" }
}
