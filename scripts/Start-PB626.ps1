# Boot the existing FEL lab kernel from Windows. No compilation or eMMC writes.
[CmdletBinding()]
param(
    [string]$Distro = 'XperiaDev',
    [string]$Loader = '/root/pb626-lab/try-fel-direct.sh'
)
$ErrorActionPreference = 'Stop'
foreach ($command in @('wsl.exe', 'usbipd.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Missing Windows command: $command"
    }
}
& wsl.exe -d $Distro -u root -- true
if ($LASTEXITCODE -ne 0) { throw "Cannot initialize WSL distribution $Distro" }

$devices = @(& usbipd.exe list)
$matches = @($devices | Where-Object { $_ -match '(?i)1f3a:efe8' -and $_ -match '^\s*\d+-\d+\s+' })
if ($matches.Count -ne 1) {
    throw "Expected exactly one PocketBook in FEL mode (1f3a:efe8), found $($matches.Count). Check usbipd list."
}
$busid = [regex]::Match($matches[0], '^\s*(\d+-\d+)').Groups[1].Value
Write-Host "PocketBook FEL: BUSID $busid"
& usbipd.exe attach --wsl --busid $busid
if ($LASTEXITCODE -ne 0) {
    throw "USB attach failed. In elevated PowerShell run: usbipd bind --busid $busid, then rerun this script."
}
Write-Host "Uploading the known lab kernel via USB (RAM only) ..."
$commandLine = "lsusb -d 1f3a:efe8 >/dev/null && exec '$Loader'"
& wsl.exe -d $Distro -u root -- bash -lc $commandLine
if ($LASTEXITCODE -ne 0) { throw 'FEL upload failed. The stock eMMC was not modified.' }
Write-Host 'FEL upload finished. Check Windows for USB gadget COM port 0525:a4a7.'
