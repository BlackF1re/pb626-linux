#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Install','Backup','Restore','Preflight')][string]$Action,
    [string]$DataDir,
    [string]$Distro='Ubuntu',
    [switch]$UseRunningRecovery
)
$ErrorActionPreference='Stop'
$kit=$PSScriptRoot
if (!$DataDir) { $DataDir=Join-Path $kit 'private' }
if (!$IsWindows -and !$IsLinux) { throw 'Only Windows and Linux are supported.' }
if (!$IsWindows -and ((& id -u) -ne '0')) { throw 'Run sudo pwsh -File PB626.ps1 on Linux.' }
if (!$Action) {
    Write-Host 'PocketBook 626 Plus (late ELAN/eMMC)'
    Write-Host '1 - Install Debian (backs up factory first)'
    Write-Host '2 - Backup only'
    Write-Host '3 - Restore a verified dump'
    Write-Host '4 - Read-only preflight of a verified dump'
    $Action=switch (Read-Host 'Choose 1-4') {
        '1' {'Install'} '2' {'Backup'} '3' {'Restore'} '4' {'Preflight'}
        default {throw 'Cancelled'}
    }
}
# Verify the trusted public kit before invoking any included script. Paths
# in the release manifest are relative, with no traversal or private files.
$manifest=Join-Path $kit 'SHA256SUMS'
$seen=@{}
foreach ($line in Get-Content -LiteralPath $manifest) {
    if ($line -notmatch '^([a-f0-9]{64})  ([A-Za-z0-9_.+/-]+)$') { throw 'Malformed kit manifest' }
    $digest=$Matches[1]; $name=$Matches[2]
    if ($name.StartsWith('/') -or $name.Split('/') -contains '..' -or $seen.ContainsKey($name)) { throw 'Unsafe kit manifest' }
    $seen[$name]=$true
    if ((Get-FileHash -LiteralPath (Join-Path $kit $name)).Hash -ne $digest) { throw "Kit hash mismatch: $name" }
}
foreach ($required in @('recovery/fel-boot.sh','recovery/Start-PB626.ps1','recovery/SHA256SUMS','tools/Backup-PB626Fast.ps1','tools/Restore-PB626Fast.ps1','tools/SHA256SUMS.fast','tools/pb626-restore-fast.sh','tools/pb626-restore-scan.gz','source/scripts/prepare-install.sh','native/SHA256SUMS','native/BUILD-COMMIT','recovery/BUILD-COMMIT')) {
    if (!$seen.ContainsKey($required)) { throw "Missing kit file: $required" }
}
if ((Get-Content -Raw (Join-Path $kit 'native/BUILD-COMMIT')).Trim() -ne (Get-Content -Raw (Join-Path $kit 'recovery/BUILD-COMMIT')).Trim()) { throw 'Mixed source revisions' }

function WslPath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw 'Use a local Windows drive, not a UNC path.' }
    return "/mnt/$($Matches[1].ToLowerInvariant())/$($Matches[2].Replace('\','/'))"
}
function Run-Linux([string[]]$Arguments) {
    if ($IsWindows) { & wsl.exe -d $Distro -u root -- @Arguments }
    else { $exe=$Arguments[0]; $tail=@($Arguments | Select-Object -Skip 1); & $exe @tail }
    if ($LASTEXITCODE -ne 0) { throw "Linux command failed (exit $LASTEXITCODE)" }
}
function LinuxPath([string]$Path) {
    if ($IsWindows) { return WslPath $Path }
    return [IO.Path]::GetFullPath($Path)
}
function Find-RecoveryPort {
    if ($IsWindows) {
        $ports=@(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -match 'VID_0525&PID_A4A7' -and $_.FriendlyName -match '\(COM[1-9][0-9]*\)'
        } | ForEach-Object { [regex]::Match($_.FriendlyName,'\((COM[1-9][0-9]*)\)').Groups[1].Value })
    } else {
        $ports=@(Get-ChildItem -Path '/dev/serial/by-id/*PB626RECOVERY*' -ErrorAction SilentlyContinue | ForEach-Object {
            (& readlink -f $_.FullName)
        } | Where-Object { $_ -match '^/dev/ttyACM[0-9]+$' })
    }
    if ($ports.Count -gt 1) { throw 'Multiple recovery serial ports. Disconnect other readers.' }
    if ($ports.Count -eq 1) { return $ports[0] }
}
$lab=Join-Path $kit 'fel-inputs'
if (!$UseRunningRecovery -or $Action -eq 'Install') {
    foreach ($name in @('pb626-spl.bin','direct-entry.bin','sunxi-fel')) {
        if (!(Test-Path -LiteralPath (Join-Path $lab $name) -PathType Leaf)) { throw "Missing verified private FEL input: $name" }
    }
    if ((Get-FileHash -LiteralPath (Join-Path $lab 'pb626-spl.bin')).Hash -ne '7543ab1379d19cd07cd01e7ea3ff7d257aada22f770d0e937a6ae0605732a38f') { throw 'Unknown SPL' }
    if ((Get-Item (Join-Path $lab 'direct-entry.bin')).Length -ne 52) { throw 'Wrong private entry stub' }
}
if ($Action -eq 'Install') {
    Write-Warning 'Installation replaces the original user partition and bootloader. Keep a verified full stock backup and do not unplug USB during writes.'
    if ((Read-Host 'Type INSTALL to continue') -cne 'INSTALL') { throw 'Cancelled' }
}
# No automatic retry of SPL. The previous launcher is preserved unchanged
# in its FEL algorithm; this merely supplies local paths and finds the ACM.
if (!$UseRunningRecovery) {
    Write-Host 'Power the reader fully off, unplug it, hold Menu and connect USB.'
    $null=Read-Host 'Press Enter when cold FEL is ready'
    $recovery=Join-Path $kit 'recovery'
    if ($IsWindows) {
        & (Join-Path $recovery 'Start-PB626.ps1') -BundleDir $recovery -Variant elan-emmc-backup -Profile diagnostic -Distro $Distro -LabDir $lab
    } else {
        Run-Linux @('env',"PB626_LAB_DIR=$lab","PB626_FEL_TOOL=$lab/sunxi-fel",'bash',(Join-Path $recovery 'fel-boot.sh'),$recovery,'elan-emmc-backup','diagnostic')
    }
}
$port=$null
for ($i=0; $i -lt 45 -and !$port; $i++) {
    $port=Find-RecoveryPort
    if (!$port) { Start-Sleep -Seconds 1 }
}
if (!$port) { throw 'No recovery ACM port. Do not repeat SPL without a full cold power cycle.' }
Write-Host "Recovery transport: $port (board/CID still checked by protocol)"
$backup=Join-Path $kit 'tools/Backup-PB626Fast.ps1'
$restore=Join-Path $kit 'tools/Restore-PB626Fast.ps1'
if ($Action -eq 'Install') {
    $null=New-Item -ItemType Directory -Force -Path $DataDir
    $stock=Join-Path $DataDir 'stock'
    $linux=Join-Path $DataDir 'linux'
    if (Test-Path -LiteralPath $linux) { throw "Output already exists: $linux (never overwritten)" }
    if (!(Test-Path -LiteralPath $stock)) { & $backup -Port $port -BackupDir $stock }
    elseif (!(Test-Path -LiteralPath (Join-Path $stock 'SHA256SUMS'))) { throw 'Incomplete stock backup; retain it and use another DataDir' }
    else {
        Write-Warning "Using existing stock backup: $stock. The builder and restore will verify hashes and CID."
        if ((Read-Host 'Type USE STOCK to confirm') -cne 'USE STOCK') { throw 'Cancelled' }
    }
    Run-Linux @('bash',(LinuxPath (Join-Path $kit 'source/scripts/prepare-install.sh')),(LinuxPath $stock),(LinuxPath (Join-Path $kit 'native')),(LinuxPath $lab),(LinuxPath $linux))
    & $restore -Port $port -BackupDir $linux -Write
} elseif ($Action -eq 'Backup') {
    $null=New-Item -ItemType Directory -Force -Path $DataDir
    $target=Join-Path $DataDir ('backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
    & $backup -Port $port -BackupDir $target
} else {
    $target=Read-Host 'Full path to a verified backup directory'
    & $restore -Port $port -BackupDir $target -Write:($Action -eq 'Restore')
}
Write-Host 'Operation complete. Only after successful verification may you disconnect the reader.'
