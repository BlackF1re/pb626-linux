# PocketBook 626: RAM-only FEL bootstrap, optionally stage a Megi build bundle.
# Never writes the internal eMMC.
[CmdletBinding()]
param(
    [string]$Distro = 'XperiaDev',
    [string]$Loader = '/root/pb626-lab/try-fel-direct.sh',
    [string]$BundleDir = '',
    [ValidateSet('elan','cypress','focaltech','no-touch')]
    [string]$Variant = 'elan'
)
$ErrorActionPreference = 'Stop'
foreach ($command in @('wsl.exe', 'usbipd.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Missing Windows command: $command"
    }
}

& wsl.exe -d $Distro -u root -- true
if ($LASTEXITCODE -ne 0) { throw "Cannot initialize WSL distribution $Distro" }

# Copy only RAM boot inputs to the lab. Keep the known original binaries.
if ($BundleDir) {
    $resolved = (Resolve-Path -LiteralPath $BundleDir).Path
    $wslPath = (& wsl.exe -d $Distro -u root -- wslpath -a $resolved).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot translate bundle path to WSL' }

    $lab = '/root/pb626-lab'
    $backups = "$lab/megi-original-backup"
    & wsl.exe -d $Distro -u root -- mkdir -p $backups
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create FEL backup directory' }

    $staging = [ordered]@{
        'fel-kernel.zImage' = 'pb626-megi-zImage'
        'direct-board.dtb' = "pb626-$Variant.dtb"
        'direct-initramfs.cpio.gz' = 'pb626-megi-initramfs.cpio.gz'
    }
    foreach ($entry in $staging.GetEnumerator()) {
        $source = "$wslPath/$($entry.Value)"
        $target = "$lab/$($entry.Key)"
        & wsl.exe -d $Distro -u root -- test -s $source
        if ($LASTEXITCODE -ne 0) { throw "Missing bundle input: $source" }
        & wsl.exe -d $Distro -u root -- cp -n $target "$backups/$($entry.Key)"
        if ($LASTEXITCODE -ne 0) { throw "Cannot back up: $target" }
        & wsl.exe -d $Distro -u root -- cp $source $target
        if ($LASTEXITCODE -ne 0) { throw "Cannot stage: $source" }
    }
    Write-Host "Megi $Variant staged; previous inputs preserved at $backups"
}

$devices = @(& usbipd.exe list)
$matches = @($devices | Where-Object {
    $_ -match '(?i)1f3a:efe8' -and $_ -match '^\s*\d+-\d+\s+'
})
if ($matches.Count -ne 1) {
    throw "Expected exactly one PocketBook in FEL mode (1f3a:efe8), found $($matches.Count)"
}
$busid = [regex]::Match($matches[0], '^\s*(\d+-\d+)').Groups[1].Value
Write-Host "PocketBook FEL BUSID: $busid"
if ($matches[0] -notmatch '(?i)\bAttached\s*$') {
    & usbipd.exe attach --wsl --busid $busid
    if ($LASTEXITCODE -ne 0) {
        throw "USB attach failed; bind $busid via an elevated PowerShell and retry."
    }
}

Write-Host "Uploading kernel via FEL (RAM only)..."
$cmd = "lsusb -d 1f3a:efe8 >/dev/null && exec '$Loader'"
& wsl.exe -d $Distro -u root -- bash -lc $cmd
if ($LASTEXITCODE -ne 0) { throw 'FEL upload failed; factory eMMC was not modified.' }
Write-Host 'Upload finished. Find the USB Gadget COM port (0525:a4a7).'
