#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install','InstallQualified','InstallCandidate','Bootloader','RestoreBootloader','Backup','Restore','Preflight','Validate','Prepare','Recovery')][string]$Action,
    [ValidateSet('Auto','NCM','RNDIS')][string]$UsbProfile='Auto',
    [string]$DataDir,
    [switch]$UseRunningRecovery
)
$ErrorActionPreference='Stop'
$kit=$PSScriptRoot
$python=Join-Path $kit 'host\python\python.exe'
if (!$DataDir) { $DataDir=Join-Path $kit 'private' }
function Say([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Invoke-Python([string[]]$Arguments) {
    & $python @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Operation failed (exit $LASTEXITCODE). No automatic write retry." }
}
function Verify-Kit {
    $seen=@{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $kit 'SHA256SUMS')) {
        if ($line -notmatch '^([a-f0-9]{64})  ([A-Za-z0-9_.+/-]+)$') { throw 'Malformed kit manifest' }
        $digest=$Matches[1]; $name=$Matches[2]
        if ($name.StartsWith('/') -or $name.Split('/') -contains '..' -or $seen.ContainsKey($name)) { throw 'Unsafe manifest path' }
        $seen[$name]=$true
        $path=Join-Path $kit $name
        if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unexpected link: $name" }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $digest) { throw "Kit hash mismatch: $name" }
    }
    foreach ($name in @('PB626.ps1','windows-fel.py','install-direct.py','dump-network.py','host/python/python.exe','host/sunxi-fel.exe','host/fdtget.exe','host/openssl.exe','host/direct-entry.bin','native/BUILD-COMMIT','native/SHA256SUMS','native/raw-linux.img','native/pb626-rootfs.ext4.gz','native/pb626-rootfs.bmap.json','native/pb626-bt0-menu.raw','recovery/BUILD-COMMIT','recovery/pb626-megi-zImage','recovery/pb626-megi-initramfs.cpio.gz','recovery/pb626-elan-emmc-backup.dtb','recovery/pb626-elan-emmc-windows-rndis.dtb','candidate/BT0-uncaged-source-candidate.bin','qualification/emulation.json')) {
        if (!$seen.ContainsKey($name)) { throw "Missing kit file: $name" }
    }
    $native=(Get-Content -Raw -LiteralPath (Join-Path $kit 'native/BUILD-COMMIT')).Trim()
    if ($native -notmatch '^[a-f0-9]{40}$' -or $native -ne (Get-Content -Raw -LiteralPath (Join-Path $kit 'recovery/BUILD-COMMIT')).Trim()) { throw 'Mixed build revisions' }
    $report=Get-Content -Raw -LiteralPath (Join-Path $kit 'qualification/emulation.json') | ConvertFrom-Json
    if ($report.result -ne 'tested contract passed' -or $report.reference -is [string]) { throw 'Missing required SPL differential qualification' }
    Write-Host "Verified build $native ($($seen.Count) files)" -ForegroundColor Green
}
function Find-Fel {
    @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -match '^USB\\VID_1F3A&PID_EFE8(?:&|\\)' })
}
function Offer-Zadig {
    Write-Host 'FEL is not accessible. Power off, unplug, hold Menu, reconnect USB.' -ForegroundColor Yellow
    Write-Host 'For device USB ID 1F3A:EFE8 only, use Zadig: Options > List All Devices, select the FEL device, choose WinUSB, Install Driver.'
    Write-Host 'Do NOT replace the recovery Ethernet/serial driver or any other USB driver.' -ForegroundColor Yellow
    if ((Read-Host 'Open Zadig 2.9 (official download if missing)? [y/N]') -notmatch '^[yY]$') { return }
    $zadig=Join-Path $kit 'zadig-2.9.exe'
    if (!(Test-Path -LiteralPath $zadig -PathType Leaf)) {
        $dir=Join-Path $kit 'fel-inputs'
        $null=New-Item -ItemType Directory -Force -Path $dir
        $zadig=Join-Path $dir 'zadig-2.9.exe'
        if (!(Test-Path -LiteralPath $zadig -PathType Leaf)) {
            $tmp=$zadig+'.download'
            try {
                [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/pbatard/libwdi/releases/download/v1.5.1/zadig-2.9.exe' -OutFile $tmp
                if ((Get-FileHash -LiteralPath $tmp).Hash -ne '4ecaa95df3da3621486a043aef8b3050b8bafe7c901402871e816229ef82039b') { throw 'Zadig hash mismatch' }
                Move-Item -LiteralPath $tmp -Destination $zadig
            } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
        }
    }
    if ((Get-FileHash -LiteralPath $zadig).Hash -ne '4ecaa95df3da3621486a043aef8b3050b8bafe7c901402871e816229ef82039b') { throw 'Unrecognized Zadig binary' }
    Start-Process -FilePath $zadig -Verb RunAs -Wait
}
function Find-Adapter {
    # Match both the dedicated MAC and the recovery USB device, not a
    # user-selected arbitrary Ethernet adapter. Get-CimInstance exposes
    # PNPDeviceID independently of the localized adapter description.
    $cards=@(Get-CimInstance Win32_NetworkAdapter | Where-Object {
        $_.MACAddress -eq '02:50:42:62:60:02' -and $_.PNPDeviceID -match '^USB\\VID_0525&PID_A4A[27](?:&|\\)' -and $_.NetEnabled
    })
    if ($cards.Count -gt 1) { throw 'Multiple PB626 recovery adapters; disconnect other readers.' }
    if ($cards.Count -eq 1) { return [int]$cards[0].InterfaceIndex }
    return $null
}
function Wait-Adapter {
    $until=(Get-Date).AddSeconds(90)
    do {
        $index=Find-Adapter
        if ($null -ne $index) { return $index }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $until)
    throw 'Recovery network adapter not found. Check Device Manager. Windows 10: use -UsbProfile RNDIS; Windows 11: NCM. Do not install WinUSB on recovery.'
}
function Connect-Recovery {
    $index=Wait-Adapter
    $existing=@(Get-NetIPAddress -AddressFamily IPv4 -IPAddress '169.254.62.2' -ErrorAction SilentlyContinue)
    if (@($existing | Where-Object InterfaceIndex -ne $index).Count) { throw 'PB626 address is already assigned to another adapter.' }
    $script:AddedAddress=$false
    $script:RestoreDhcp=$false
    $script:AdapterIndex=$index
    if (!$existing.Count) {
        $script:RestoreDhcp=((Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4).Dhcp -eq 'Enabled')
        New-NetIPAddress -InterfaceIndex $index -IPAddress '169.254.62.2' -PrefixLength 30 -AddressFamily IPv4 | Out-Null
        $script:AddedAddress=$true
    } elseif ($existing[0].PrefixLength -ne 30) { throw 'Existing recovery address has the wrong subnet.' }
    # No default gateway, DNS changes, Internet sharing or firewall edits.
    $until=(Get-Date).AddSeconds(45)
    do {
        & $python -c 'import importlib; r=importlib.import_module("install-direct").EthernetRecovery(windows=True); print("Recovery protocol OK")' 2>$null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $until)
    throw 'Recovery did not answer the fixed protocol. No eMMC writes attempted.'
}
function Disconnect-Recovery {
    if ($script:AddedAddress) {
        Remove-NetIPAddress -InterfaceIndex $script:AdapterIndex -IPAddress '169.254.62.2' -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($script:RestoreDhcp) {
        Set-NetIPInterface -InterfaceIndex $script:AdapterIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue
    }
}
Write-Host ''
Write-Host '========================================================' -ForegroundColor DarkCyan
Write-Host '   PB626 UNCAGED  |  Native Windows firmware console' -ForegroundColor Cyan
Write-Host '   ELAN / eMMC   |  PowerShell 5.1   |  no WSL' -ForegroundColor Gray
Write-Host '========================================================' -ForegroundColor DarkCyan
if (!$Action) {
    Write-Host '  1   Install paired Debian + kernel (keep current BT0)'
    Write-Host '  2   Install paired Debian + kernel + qualified BT0'
    Write-Host '  3   Install paired Debian + kernel + NEW experimental BT0' -ForegroundColor Yellow
    Write-Host '  4   Update only BT0 to NEW experimental candidate' -ForegroundColor Yellow
    Write-Host '  5   Restore only the historical qualified BT0'
    Write-Host '  6   Backup complete eMMC'
    Write-Host '  7   Restore verified eMMC dump'
    Write-Host '  8   Read-only restore preflight'
    Write-Host '  9   Boot RAM recovery only'
    Write-Host ' 10   Verify package (offline)'
    Write-Host ' 11   Prepare historical FEL SPL (no device access)'
    $Action=switch (Read-Host 'Select 1-11') {
        '1' {'Install'} '2' {'InstallQualified'} '3' {'InstallCandidate'} '4' {'Bootloader'}
        '5' {'RestoreBootloader'} '6' {'Backup'} '7' {'Restore'} '8' {'Preflight'}
        '9' {'Recovery'} '10' {'Validate'} '11' {'Prepare'} default {throw 'Cancelled'}
    }
}
Verify-Kit
if ($Action -eq 'Validate') { return }
if ($Action -eq 'Prepare') { Invoke-Python @((Join-Path $kit 'windows-fel.py'),'prepare'); return }
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PB626.cmd as administrator (USB adapter configuration requires elevation).'
}
if ($Action -in @('InstallCandidate','Bootloader')) {
    Write-Warning 'NEW SPL is experimental. A successful CI or FEL RAM boot does NOT prove recovery after replacing installed BT0. Keep a complete verified backup and independent hardware recovery. Deep resume is NOT enabled by this candidate.'
    if ((Read-Host 'Type EXPERIMENTAL to continue') -cne 'EXPERIMENTAL') { throw 'Cancelled' }
}
if ($Action -like 'Install*') { Write-Warning 'Installation replaces the complete Debian p1 partition, including user files. Back up first.' }
if (!$UseRunningRecovery) {
    Invoke-Python @((Join-Path $kit 'windows-fel.py'),'prepare')
    Say 'STEP 1 / Cold FEL'
    $null=Read-Host 'Power off fully, unplug, hold Menu, reconnect USB, then press Enter'
    $fel=@(Find-Fel)
    if ($fel.Count -gt 1) { throw 'Multiple FEL devices. Disconnect other readers.' }
    $usable=$false
    if ($fel.Count -eq 1) {
        & $python (Join-Path $kit 'windows-fel.py') probe
        $usable=($LASTEXITCODE -eq 0)
    }
    if (!$usable) {
        Offer-Zadig
        $null=Read-Host 'After driver setup, re-enter cold FEL and press Enter'
        if (@(Find-Fel).Count -ne 1) { throw 'Expected exactly one Allwinner FEL device' }
        Invoke-Python @((Join-Path $kit 'windows-fel.py'),'probe')
    }
    $profile=$UsbProfile.ToLowerInvariant()
    if ($profile -eq 'auto') {
        $build=[int](Get-CimInstance Win32_OperatingSystem).BuildNumber
        $profile=if ($build -ge 22000) {'ncm'} else {'rndis'}
    }
    Say "STEP 2 / Load recovery into RAM ($profile)"
    Invoke-Python @((Join-Path $kit 'windows-fel.py'),'boot','--profile',$profile)
}
Say 'STEP 3 / Establish native USB Ethernet connection'
$script:AddedAddress=$false; $script:RestoreDhcp=$false
try {
    Connect-Recovery
    if ($Action -eq 'Recovery') { Write-Host 'RAM recovery verified. No eMMC write.' -ForegroundColor Green; return }
    Say 'STEP 4 / Device and data verification'
    if ($Action -in @('Install','InstallQualified','InstallCandidate','Bootloader','RestoreBootloader')) {
        $mode=switch ($Action) { 'Install' {'keep'} 'InstallQualified' {'qualified'} 'InstallCandidate' {'candidate'} 'Bootloader' {'candidate'} 'RestoreBootloader' {'qualified'} }
        if ($mode -eq 'qualified') { Invoke-Python @((Join-Path $kit 'windows-fel.py'),'prepare') }
        $argsList=@((Join-Path $kit 'install-direct.py'),'--kit',$kit,'--windows','--spl',$mode)
        if ($Action -in @('Bootloader','RestoreBootloader')) { $argsList+='--spl-only' }
        Invoke-Python $argsList
    } else {
        if ($Action -eq 'Backup') {
            $null=New-Item -ItemType Directory -Force -Path $DataDir
            $target=Join-Path $DataDir ('backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
        } else {
            $target=Read-Host 'Path to verified dump directory'
            if (!$target) { throw 'Cancelled' }
        }
        Invoke-Python @((Join-Path $kit 'dump-network.py'),$Action.ToLowerInvariant(),$target,'--windows')
    }
    Write-Host 'SUCCESS / All requested operations verified.' -ForegroundColor Green
} finally { Disconnect-Recovery }
