#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Install','InstallFromDump','Backup','Restore','Preflight','Flash','Prepare')][string]$Action,
    [string]$DataDir,
    [string]$Distro='Ubuntu',
    [switch]$UseRunningRecovery,
    [switch]$SkipBackup,
    [string]$StockDir,
    [string]$ImageDir,
    [switch]$EnableRecoverySD,
    [switch]$PrepareFelInputs,
    [string]$OriginalUboot,
    [switch]$SD
)
$ErrorActionPreference='Stop'
$kit=$PSScriptRoot
if (!$DataDir) { $DataDir=Join-Path $kit 'private' }
if (!$IsWindows -and !$IsLinux) { throw 'Only Windows and Linux are supported.' }
if (!$IsWindows -and ((& id -u) -ne '0')) { throw 'Run sudo pwsh -File PB626.ps1 on Linux.' }
if (!$Action) {
    Write-Host 'PocketBook 626 Plus (late ELAN/eMMC)'
    Write-Host '1 - Install Debian directly from the paired Actions artifact (no backup)'
    Write-Host '2 - Backup only'
    Write-Host '3 - Restore a verified dump'
    Write-Host '4 - Read-only preflight of a verified dump'
    Write-Host '5 - Legacy offline installation from an existing full dump'
    Write-Host '6 - Restore a complete assembled eMMC image (legacy Flash alias)'
    Write-Host '7 - Backup microSD (experimental MMC0 profile)'
    Write-Host '8 - Restore microSD (experimental MMC0 profile)'
    Write-Host '9 - Preflight microSD restore'
    Write-Host '10 - Prepare missing FEL input files (no device access)'
    $Action=switch (Read-Host 'Choose 1-10') {
        '1' {'Install'} '2' {'Backup'} '3' {'Restore'} '4' {'Preflight'}
        '5' {$SkipBackup=$true; 'InstallFromDump'}
        '6' {'Flash'}
        '7' {$SD=$true; 'Backup'}
        '8' {$SD=$true; 'Restore'}
        '9' {$SD=$true; 'Preflight'}
        '10' {'Prepare'}
        default {throw 'Cancelled'}
    }
}
if ($SD) {
    if ($Action -notin @('Backup','Restore','Preflight')) { throw 'SD supports Backup, Restore, Preflight; native firmware installs only to eMMC' }
    $EnableRecoverySD=$true
}
if ($Action -eq 'Install' -and ($SkipBackup -or $StockDir)) { $Action='InstallFromDump' }
if ($SkipBackup -and $Action -ne 'InstallFromDump') { throw '-SkipBackup applies only to the legacy InstallFromDump path' }
if ($Action -eq 'InstallFromDump' -and $SkipBackup) {
    if (!$StockDir) { $StockDir=Join-Path $DataDir 'stock' }
    if (!(Test-Path -LiteralPath (Join-Path $StockDir 'SHA256SUMS') -PathType Leaf)) {
        $StockDir=Read-Host 'Path to an existing verified factory/native dump'
        if (!$StockDir -or !(Test-Path -LiteralPath (Join-Path $StockDir 'SHA256SUMS') -PathType Leaf)) {
            throw 'Skipping a new backup requires a previously verified dump. Or use Flash for an already assembled image.'
        }
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
foreach ($required in @('dump-network.py','recovery/fel-boot.sh','recovery/Start-PB626.ps1','recovery/SHA256SUMS','tools/Backup-PB626Fast.ps1','tools/Restore-PB626Fast.ps1','tools/SHA256SUMS.fast','tools/pb626-restore-fast.sh','tools/pb626-restore-scan.gz','source/scripts/prepare-install.sh','native/SHA256SUMS','native/BUILD-COMMIT','recovery/BUILD-COMMIT')) {
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
if ($PrepareFelInputs -or $Action -eq 'Prepare') {
    if (!$seen.ContainsKey('source/scripts/prepare-fel-inputs.py') -or !$seen.ContainsKey('fel-host/SHA256SUMS')) { throw 'Missing verified FEL host preparation files' }
    Write-Warning 'The entry and SPL are hash-qualified; the rebuilt host executable still needs physical USB qualification. Missing SPL is downloaded directly from its original author and must match the laboratory hash. Existing inputs are not overwritten.'
    $prepare=@('python3',(LinuxPath (Join-Path $kit 'source/scripts/prepare-fel-inputs.py')),'--host',(LinuxPath (Join-Path $kit 'fel-host')),'--output',(LinuxPath $lab))
    if ($OriginalUboot) { $prepare+=@('--uboot',(LinuxPath $OriginalUboot)) }
    Run-Linux $prepare
    if ($Action -eq 'Prepare') { Write-Host 'FEL inputs prepared. No reader accessed.'; return }
}
if (!$UseRunningRecovery -or $Action -in @('Install','InstallFromDump')) {
    foreach ($name in @('pb626-spl.bin','direct-entry.bin','sunxi-fel')) {
        if (!(Test-Path -LiteralPath (Join-Path $lab $name) -PathType Leaf)) { throw "Missing verified private FEL input: $name" }
    }
    if ((Get-FileHash -LiteralPath (Join-Path $lab 'pb626-spl.bin')).Hash -ne '7543ab1379d19cd07cd01e7ea3ff7d257aada22f770d0e937a6ae0605732a38f') { throw 'Unknown SPL' }
    if ((Get-FileHash -LiteralPath (Join-Path $lab 'direct-entry.bin')).Hash -ne '1a0044b4533ce91bb1f19f5fef9f1356242d3855cadd4087cc1c6a6ac22a21dd') { throw 'Wrong entry stub' }
}
if ($Action -eq 'Install') {
    foreach ($required in @('install-direct.py','native/pb626-rootfs.ext4.gz','native/pb626-rootfs.bmap.json','native/pb626-bt0-menu.raw')) {
        if (!$seen.ContainsKey($required)) { throw "Missing direct-install artifact: $required. Download a new paired flash kit." }
    }
    Write-Warning 'Direct install replaces p1 (all user data), raw kernel/DTB and tested BT0. No backup is created; do not unplug during writes.'
}
if ($Action -eq 'InstallFromDump') {
    Write-Warning 'Installation replaces BT0, raw kernel/DTB and the entire rootfs partition. All eMMC regions are verified and changed blocks restored. Keep a verified stock backup and do not unplug USB during writes.'
    if ((Read-Host 'Type INSTALL to continue') -cne 'INSTALL') { throw 'Cancelled' }
}
# No automatic retry of SPL. The previous launcher is preserved unchanged
# in its FEL algorithm; this merely supplies local paths and finds the ACM.
if (!$UseRunningRecovery) {
    Write-Host 'Power the reader fully off, unplug it, hold Menu and connect USB.'
    $null=Read-Host 'Press Enter when cold FEL is ready'
    $recovery=Join-Path $kit 'recovery'
    $variant=if ($EnableRecoverySD) { 'elan-emmc-sd-backup' } else { 'elan-emmc-backup' }
    if ($IsWindows) {
        & (Join-Path $recovery 'Start-PB626.ps1') -BundleDir $recovery -Variant $variant -Profile diagnostic -Distro $Distro -LabDir $lab
    } else {
        Run-Linux @('env',"PB626_LAB_DIR=$lab","PB626_FEL_TOOL=$lab/sunxi-fel",'bash',(Join-Path $recovery 'fel-boot.sh'),$recovery,$variant,'diagnostic')
    }
}
# The composite gadget must be attached to Linux as a whole, not opened
# through Windows' serial driver. Keep ACM for an emergency shell.
if ($IsWindows) {
    $devices=@()
    for ($i=0; $i -lt 45 -and $devices.Count -eq 0; $i++) {
        $devices=@(& usbipd.exe list | Where-Object { $_ -match '^\s*\d+-\d+\s+0525:a4a7\b' })
        if (!$devices.Count) { Start-Sleep -Seconds 1 }
    }
    if ($devices.Count -ne 1) { throw 'Expected one PB626 recovery USB gadget' }
    $busid=[regex]::Match($devices[0],'^\s*(\d+-\d+)').Groups[1].Value
    if ($devices[0] -notmatch 'Attached\s*$') {
        if ($devices[0] -match 'Not shared\s*$') {
            & usbipd.exe bind --busid $busid
            if ($LASTEXITCODE -ne 0) { throw 'Run elevated PowerShell to bind the recovery gadget' }
        }
        & usbipd.exe attach --wsl --busid $busid
        if ($LASTEXITCODE -ne 0) { throw 'Recovery USB attach failed' }
    }
}
Run-Linux @('python3','-c','import sys; assert sys.version_info >= (3,7)')
$direct=LinuxPath (Join-Path $kit 'install-direct.py')
$dump=LinuxPath (Join-Path $kit 'dump-network.py')
$sdargs=@()
if ($SD) { $sdargs+= '--sd' }
if ($Action -eq 'Install') {
    Run-Linux @('python3',$direct,'--kit',(LinuxPath $kit),'--distro',$Distro)
} elseif ($Action -eq 'InstallFromDump') {
    $null=New-Item -ItemType Directory -Force -Path $DataDir
    $stock=if ($StockDir) { $StockDir } else { Join-Path $DataDir 'stock' }
    $linux=Join-Path $DataDir ('linux-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    if (!$SkipBackup) {
        if (Test-Path -LiteralPath $stock) { $stock=Join-Path $DataDir ('backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
        Run-Linux @('python3',$dump,'backup',(LinuxPath $stock))
    }
    Run-Linux @('bash',(LinuxPath (Join-Path $kit 'source/scripts/prepare-install.sh')),(LinuxPath $stock),(LinuxPath (Join-Path $kit 'native')),(LinuxPath $lab),(LinuxPath $linux))
    Run-Linux @('python3',$dump,'restore',(LinuxPath $linux))
} elseif ($Action -eq 'Backup') {
    $null=New-Item -ItemType Directory -Force -Path $DataDir
    $target=Join-Path $DataDir ('backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    Run-Linux (@('python3',$dump,'backup',(LinuxPath $target))+$sdargs)
} else {
    $target=if ($ImageDir) { $ImageDir } else { Read-Host 'Full path to a verified image/backup directory' }
    $mode=if ($Action -eq 'Preflight') { 'preflight' } else { 'restore' }
    Run-Linux (@('python3',$dump,$mode,(LinuxPath $target))+$sdargs)
}
Write-Host 'Operation complete. Only after successful verification may you disconnect the reader.'
