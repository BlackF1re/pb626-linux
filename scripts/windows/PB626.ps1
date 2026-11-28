#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install','InstallQualified','InstallCandidate','InstallDeepLab','Bootloader','RestoreBootloader','RootfsOnly','KernelOnly','Backup','ResumeBackup','Restore','Preflight','Validate','Prepare','Recovery','RecoveryTest')][string]$Action,
    [ValidateSet('Auto','NCM','RNDIS')][string]$UsbProfile='Auto',
    [string]$DataDir,
    [string]$BackupDir,
    [switch]$UseRunningRecovery,
    [switch]$PauseOnExit
)
$ErrorActionPreference='Stop'
$script:JournalPath=$null
$script:FelStarted=$false
$script:HandedOff=$false
$script:ChildExit=0
$script:Mutex=$null
$script:OwnMutex=$false
function Cancel-Operation { throw [OperationCanceledException]::new('Cancelled by user') }
function Main {
$kit=$PSScriptRoot
$python=Join-Path $kit 'host\python\python.exe'
$firmwareProfile=(Get-Content -Raw -LiteralPath (Join-Path $kit 'PROFILE')).Trim()
if ($firmwareProfile -notin @('standard','deep-lab')) { throw 'Unknown firmware profile' }
$candidate=if ($firmwareProfile -eq 'deep-lab') { 'candidate/BT0-uncaged-deep-candidate.bin' } else { 'candidate/BT0-uncaged-source-candidate.bin' }
if (!$DataDir) { $DataDir=Join-Path $kit 'private' }
function Say([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Invoke-Python([string[]]$Arguments) {
    $previous=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $python @Arguments
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$previous }
    if ($code -eq 2) { Cancel-Operation }
    if ($code -ne 0) { throw "Failed (exit $code). No automatic write retry." }
}
function Invoke-Probe([string[]]$Arguments) {
    $previous=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $lines=@(& $python @Arguments 2>&1)
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$previous }
    [pscustomobject]@{Code=$code; Lines=$lines}
}
function Read-Directory([string]$Prompt,[string]$Default='') {
    while ($true) {
        $hint=if ($Default) { " [$Default]" } else { '' }
        $answer=(Read-Host "$Prompt$hint (0 = cancel)").Trim()
        if ($answer -eq '0') { Cancel-Operation }
        if (!$answer) { $answer=$Default }
        $answer=$answer.Trim('"')
        if ($answer -and (Test-Path -LiteralPath $answer -PathType Container)) { return [IO.Path]::GetFullPath($answer) }
        Write-Host 'Directory not found. Try again.' -ForegroundColor Yellow
    }
}
function Verify-Kit {
    $seen=@{}
    $entries=@(Get-Content -LiteralPath (Join-Path $kit 'SHA256SUMS'))
    $n=0
    Say 'Verifying package integrity...'
    foreach ($line in $entries) {
        $n++
        if ($line -notmatch '^([a-f0-9]{64})  ([A-Za-z0-9_.+/-]+)$') { throw 'Malformed kit manifest' }
        $digest=$Matches[1]; $name=$Matches[2]
        if ($name.StartsWith('/') -or $name.Split('/') -contains '..' -or $seen.ContainsKey($name)) { throw 'Unsafe manifest path' }
        $seen[$name]=$true
        $path=Join-Path $kit $name
        Write-Progress -Activity 'Verify firmware package' -Status "$n/$($entries.Count) : $name" -PercentComplete (100*$n/[Math]::Max(1,$entries.Count))
        if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unexpected link: $name" }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $digest) { throw "Kit hash mismatch: $name" }
    }
    Write-Progress -Activity 'Verify firmware package' -Completed
    foreach ($name in @('PB626.ps1','windows-fel.py','install-direct.py','dump-network.py','host/python/python.exe','host/sunxi-fel.exe','host/fdtget.exe','host/openssl.exe','host/direct-entry.bin','native/BUILD-COMMIT','native/KERNELRELEASE','native/SHA256SUMS','native/raw-linux.img','native/pb626-rootfs.ext4.gz','native/pb626-rootfs.bmap.json','native/pb626-modules.sha256','native/pb626-bt0-menu.raw','recovery/BUILD-COMMIT','recovery/pb626-megi-zImage','recovery/pb626-megi-initramfs.cpio.gz','recovery/pb626-elan-emmc-backup.dtb','recovery/pb626-elan-emmc-windows-rndis.dtb',$candidate,'qualification/emulation.json','PROFILE')) {
        if (!$seen.ContainsKey($name)) { throw "Missing kit file: $name" }
    }
    $native=(Get-Content -Raw -LiteralPath (Join-Path $kit 'native/BUILD-COMMIT')).Trim()
    if ($native -notmatch '^[a-f0-9]{40}$' -or $native -ne (Get-Content -Raw -LiteralPath (Join-Path $kit 'recovery/BUILD-COMMIT')).Trim()) { throw 'Mixed build revisions' }
    $report=Get-Content -Raw -LiteralPath (Join-Path $kit 'qualification/emulation.json') | ConvertFrom-Json
    if ($report.result -ne 'tested contract passed' -or $report.reference -is [string]) { throw 'Missing required SPL differential qualification' }
    $expected=if ($firmwareProfile -eq 'deep-lab') { $report.deep_cold_path.sha256 } else { $report.native.sha256 }
    if (!$expected -or (Get-FileHash -LiteralPath (Join-Path $kit $candidate)).Hash -ne $expected) { throw 'Candidate not bound to differential report' }
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
    $parents=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match '^USB\\VID_0525&PID_A4A[27]\\'
    })
    if (@($parents | Where-Object Class -eq 'Ports').Count) {
        throw 'Recovery USB driver conflict (COM port on parent). In Device Manager, select USB Composite Device from C:\Windows\INF\usb.inf. Never use WinUSB on recovery.'
    }
    throw 'Recovery Ethernet missing. Check USB Composite Device and NCM/RNDIS driver; try -UsbProfile RNDIS after cold power-off.'
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
        $script:AddedAddress=$true
        New-NetIPAddress -InterfaceIndex $index -IPAddress '169.254.62.2' -PrefixLength 30 -AddressFamily IPv4 -PolicyStore ActiveStore | Out-Null
    } elseif ($existing[0].PrefixLength -ne 30) { throw 'Existing recovery address has the wrong subnet.' }
    # No default gateway, DNS changes, Internet sharing or firewall edits.
    $until=(Get-Date).AddSeconds(65)
    $verb=if ($Action -eq 'Recovery') { 'hello' } else { 'ready' }
    do {
        Write-Progress -Activity 'Connecting to RAM recovery' -Status 'Waiting for recovery and storage'
        $result=Invoke-Probe @((Join-Path $kit 'windows-fel.py'),$verb)
        if ($result.Code -eq 0) {
            Write-Progress -Activity 'Connecting to RAM recovery' -Completed
            Write-Host ($result.Lines -join ' ') -ForegroundColor Green
            return
        }
        if (($result.Lines -join ' ') -match 'Wrong RAM recovery build/profile') { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $until)
    Write-Progress -Activity 'Connecting to RAM recovery' -Completed
    throw "Recovery unavailable or incompatible: $($result.Lines -join ' '). Boot recovery from this bundle."
}
function Disconnect-Recovery {
    if ($script:AddedAddress) {
        Remove-NetIPAddress -InterfaceIndex $script:AdapterIndex -IPAddress '169.254.62.2' -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
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
Write-Host "  Profile: $firmwareProfile | Data: $DataDir" -ForegroundColor Gray
if (!$Action) {
    if ($firmwareProfile -eq 'deep-lab') {
        $menu=[ordered]@{'1'=@('InstallDeepLab','Install experimental deep kernel + modules + resume SPL');'2'=@('Backup','Back up complete eMMC');'3'=@('Restore','Restore verified eMMC dump');'4'=@('Preflight','Read-only restore preflight');'5'=@('Recovery','Boot RAM recovery only');'6'=@('Validate','Verify package (offline)');'7'=@('Prepare','Prepare historical FEL inputs');'8'=@('ResumeBackup','Resume incomplete eMMC backup');'9'=@('RecoveryTest','Test recovery and read-only storage')}
        Write-Warning 'DEEP LAB: not hardware qualified.'
    } else {
        $menu=[ordered]@{'1'=@('Install','Update Debian + kernel; keep recognized BT0');'2'=@('InstallQualified','Install Debian + kernel + historical qualified BT0');'3'=@('InstallCandidate','Install Debian + kernel + experimental BT0');'4'=@('Bootloader','Update ONLY BT0 (experimental)');'5'=@('RestoreBootloader','Restore ONLY historical BT0');'6'=@('Backup','Back up complete eMMC');'7'=@('Restore','Restore verified eMMC dump');'8'=@('Preflight','Read-only restore preflight');'9'=@('Recovery','Boot RAM recovery only');'10'=@('Validate','Verify package (offline)');'11'=@('Prepare','Prepare historical FEL inputs');'12'=@('RootfsOnly','Replace ONLY Debian rootfs (paired kernel required)');'13'=@('KernelOnly','Replace ONLY kernel/DTB (matching modules required)');'14'=@('ResumeBackup','Resume incomplete eMMC backup');'15'=@('RecoveryTest','Test recovery and read-only storage')}
    }
    foreach ($key in $menu.Keys) {
        $color=if ($menu[$key][0] -in @('InstallDeepLab','InstallCandidate','Bootloader','Restore','InstallQualified','RestoreBootloader','RootfsOnly','KernelOnly')) {'Yellow'} else {'Gray'}
        Write-Host ('  {0,2}   {1}' -f $key,$menu[$key][1]) -ForegroundColor $color
    }
    Write-Host '   0   Exit'
    while (!$Action) {
        $choice=(Read-Host 'Select operation').Trim()
        if ($choice -eq '0' -or !$choice) { Cancel-Operation }
        if ($menu.Contains($choice)) { $Action=$menu[$choice][0] }
        else { Write-Host 'Invalid choice. Enter a listed number.' -ForegroundColor Yellow }
    }
}
if ($firmwareProfile -eq 'deep-lab' -and $Action -in @('Install','InstallQualified','InstallCandidate','Bootloader','RestoreBootloader','RootfsOnly','KernelOnly')) { throw 'Deep profile requires the paired InstallDeepLab action' }
if ($firmwareProfile -eq 'standard' -and $Action -eq 'InstallDeepLab') { throw 'Use the separate deep lab bundle' }
if ($Action -eq 'Validate') {
    Verify-Kit
    Invoke-Python @((Join-Path $kit 'windows-fel.py'),'validate')
    return
}
if ($Action -eq 'Prepare') { Verify-Kit; Invoke-Python @((Join-Path $kit 'windows-fel.py'),'prepare'); return }
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($DataDir.Contains('"')) { throw 'Invalid data directory' }
    $fullData=[IO.Path]::GetFullPath($DataDir)
    if ($fullData.EndsWith('\')) { $fullData+='.' }
    $launch='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Action '+$Action+' -UsbProfile '+$UsbProfile+' -DataDir "'+$fullData+'"'
    if ($UseRunningRecovery) { $launch+=' -UseRunningRecovery' }
    if ($PauseOnExit) { $launch+=' -PauseOnExit' }
    if ($BackupDir) {
        $fullBackup=[IO.Path]::GetFullPath($BackupDir)
        if ($fullBackup.EndsWith('\')) { $fullBackup+='.' }
        if ($fullBackup.Contains('"')) { throw 'Invalid backup directory' }
        $launch+=' -BackupDir "'+$fullBackup+'"'
    }
    $child=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $launch -Wait -PassThru
    $script:HandedOff=$true
    $script:ChildExit=$child.ExitCode
    return
}
$script:Mutex=[Threading.Mutex]::new($false,'Global\PB626-Windows-Flasher')
try { $script:OwnMutex=$script:Mutex.WaitOne(0) }
catch [Threading.AbandonedMutexException] { $script:OwnMutex=$true }
if (!$script:OwnMutex) { throw 'Another PB626 flasher is running.' }
Verify-Kit
$journalDir=Join-Path $DataDir 'sessions'
$null=New-Item -ItemType Directory -Force -Path $journalDir
$script:JournalPath=Join-Path $journalDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$PID+'.txt')
if ($Action -in @('InstallCandidate','Bootloader','InstallDeepLab') -and $BackupDir) {
    if (!(Test-Path -LiteralPath (Join-Path $BackupDir 'SHA256SUMS') -PathType Leaf)) { throw 'Backup manifest missing' }
}
if (!$UseRunningRecovery -and $UsbProfile -eq 'Auto' -and $null -ne (Find-Adapter)) {
    Say 'Reusing RAM recovery (identity will be checked).'
    $UseRunningRecovery=$true
}
function Start-ColdRecovery {
    Invoke-Python @((Join-Path $kit 'windows-fel.py'),'prepare')
    Say 'STEP 1 / Cold FEL'
    while ($true) {
        $answer=Read-Host 'Cold FEL: power off, hold Menu, reconnect USB. Enter / 0=cancel'
        if ($answer -eq '0') { Cancel-Operation }
        $fel=@(Find-Fel)
        if ($fel.Count -gt 1) { throw 'Multiple FEL devices. Disconnect other readers.' }
        if ($fel.Count -eq 1) {
            $result=Invoke-Probe @((Join-Path $kit 'windows-fel.py'),'probe')
            if ($result.Code -eq 0) {
                Write-Host 'FEL: Allwinner A13 accessible.' -ForegroundColor Green
                break
            }
            Write-Host ($result.Lines -join ' ') -ForegroundColor Yellow
            if (($result.Lines -join ' ') -match 'Unexpected FEL SoC') { throw 'Incorrect SoC; refusing to initialize DRAM' }
            Offer-Zadig
        } else {
            Write-Host 'FEL not found (1F3A:EFE8). Check cable and Menu.' -ForegroundColor Yellow
            if ((Read-Host 'Open driver instructions anyway? [y/N]') -match '^[yY]$') { Offer-Zadig }
        }
    }
    $profile=$UsbProfile.ToLowerInvariant()
    if ($profile -eq 'auto') {
        $build=[int](Get-CimInstance Win32_OperatingSystem).BuildNumber
        $profile=if ($build -ge 22000) {'ncm'} else {'rndis'}
    }
    Say "STEP 2 / Load recovery into RAM ($profile)"
    $script:FelStarted=$true
    Invoke-Python @((Join-Path $kit 'windows-fel.py'),'boot','--profile',$profile)
}
function Invoke-Transfer([string[]]$Arguments) {
    while ($true) {
        $previous=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            & $python @Arguments
            $code=$LASTEXITCODE
        } finally { $ErrorActionPreference=$previous }
        if ($code -eq 0) { return }
        if ($code -eq 2) { Cancel-Operation }
        if ($code -ne 75) { throw "Failed (exit $code). No automatic retry." }
        Write-Warning 'USB interrupted. Keep reader powered; matching chunks will be skipped.'
        Disconnect-Recovery
        $script:AddedAddress=$false
        $script:RestoreDhcp=$false
        while ($true) {
            $answer=(Read-Host 'R=running recovery, F=already powered off (cold FEL), 0=stop').Trim()
            if ($answer -eq '0' -or !$answer) { Cancel-Operation }
            if ($answer -notin @('R','F')) { Write-Host 'Choose R, F or 0.' -ForegroundColor Yellow; continue }
            if ($answer -eq 'F') {
                Start-ColdRecovery
            }
            try {
                Connect-Recovery
                break
            } catch {
                Write-Host "Reconnect failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Disconnect-Recovery
                $script:AddedAddress=$false
                $script:RestoreDhcp=$false
            }
        }
        Say 'Resuming operation; already matching chunks will be skipped.'
    }
}
if (!$UseRunningRecovery) { Start-ColdRecovery }
Say 'STEP 3 / Establish native USB Ethernet connection'
$script:AddedAddress=$false; $script:RestoreDhcp=$false
try {
    Connect-Recovery
    if ($Action -eq 'Recovery') { Write-Host 'RAM recovery verified. No eMMC write.' -ForegroundColor Green; return }
    if ($Action -eq 'RecoveryTest') {
        Invoke-Python @((Join-Path $kit 'windows-fel.py'),'test')
        return
    }
    Say 'STEP 4 / Device and data verification'
    if ($Action -in @('Install','InstallQualified','InstallCandidate','InstallDeepLab','Bootloader','RestoreBootloader','RootfsOnly','KernelOnly')) {
        $mode=switch ($Action) { 'Install' {'keep'} 'InstallQualified' {'qualified'} 'InstallCandidate' {'candidate'} 'InstallDeepLab' {'candidate'} 'Bootloader' {'candidate'} 'RestoreBootloader' {'qualified'} 'RootfsOnly' {'keep'} 'KernelOnly' {'keep'} }
        if ($mode -eq 'qualified') { Invoke-Python @((Join-Path $kit 'windows-fel.py'),'prepare') }
        $argsList=@((Join-Path $kit 'install-direct.py'),'--kit',$kit,'--windows','--spl',$mode,'--journal',$script:JournalPath)
        if ($Action -in @('Bootloader','RestoreBootloader')) { $argsList+='--spl-only' }
        if ($Action -eq 'RootfsOnly') { $argsList+='--rootfs-only' }
        if ($Action -eq 'KernelOnly') { $argsList+='--kernel-only' }
        if ($mode -eq 'candidate') {
            if ($BackupDir) { $argsList+=@('--candidate-backup',[IO.Path]::GetFullPath($BackupDir)) }
            else { $argsList+='--allow-no-backup' }
        }
        Invoke-Transfer $argsList
    } else {
        if ($Action -eq 'Backup') {
            $null=New-Item -ItemType Directory -Force -Path $DataDir
            $target=Join-Path $DataDir ('backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
        } elseif ($Action -eq 'ResumeBackup') {
            $recent=Get-ChildItem -LiteralPath $DataDir -Directory -ErrorAction SilentlyContinue | Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'pb626-emmc-cid.txt') -PathType Leaf) -and !(Test-Path -LiteralPath (Join-Path $_.FullName 'SHA256SUMS'))
            } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $default=if ($BackupDir) {$BackupDir} elseif ($recent) {$recent.FullName} else {''}
            $target=Read-Directory 'Incomplete backup directory' $default
            if (Test-Path -LiteralPath (Join-Path $target 'SHA256SUMS')) { throw 'This backup is already complete.' }
        } else {
            $target=Read-Directory 'Verified dump directory' $BackupDir
        }
        $verb=if ($Action -eq 'ResumeBackup') {'backup'} else {$Action.ToLowerInvariant()}
        Invoke-Transfer @((Join-Path $kit 'dump-network.py'),$verb,$target,'--windows','--journal',$script:JournalPath)
    }
    Write-Host 'SUCCESS / Verified.' -ForegroundColor Green
    if ($Action -in @('Install','InstallQualified','InstallCandidate','InstallDeepLab','Bootloader','RestoreBootloader','RootfsOnly','KernelOnly','Restore')) {
        Write-Host 'Power off, boot normally, then check Menu/FEL.' -ForegroundColor Green
    } else { Write-Host 'No device writes requested. Recovery remains running.' }
} finally { Disconnect-Recovery }
}
$exitCode=1
try {
    Main
    $exitCode=if ($script:HandedOff) { $script:ChildExit } else { 0 }
} catch [OperationCanceledException] {
    Write-Host 'Cancelled. No additional writes requested.' -ForegroundColor Yellow
    $exitCode=2
} catch {
    Write-Host "ERROR / $($_.Exception.Message)" -ForegroundColor Red
    $exitCode=1
} finally {
    if ($script:OwnMutex) { $script:Mutex.ReleaseMutex() }
    if ($script:Mutex) { $script:Mutex.Dispose() }
    if (!$script:HandedOff) {
        if ($exitCode -ne 0) {
            $state=@()
            if ($script:JournalPath -and (Test-Path -LiteralPath $script:JournalPath)) { $state=@(Get-Content -LiteralPath $script:JournalPath) }
            if ($state.Count -and $state[0] -eq 'writing') {
                Write-Host "WRITE STATE UNCERTAIN: $($state[1])" -ForegroundColor Red
                Write-Warning 'Keep powered. Relaunch with -UseRunningRecovery; matching chunks are skipped.'
            } elseif ($state.Count -and $state[0] -eq 'verified') {
                Write-Host 'Device writes were verified, but a later host-side step failed. Check the reported error before disconnecting.' -ForegroundColor Yellow
            } elseif ($script:FelStarted) {
                Write-Warning 'No eMMC writes. Reuse recovery or fully power off before FEL.'
            } else { Write-Host 'No eMMC write was started in this session.' }
            if ($script:JournalPath -and (Test-Path -LiteralPath $script:JournalPath)) { Write-Host "Session record: $script:JournalPath" }
        }
        if ($PauseOnExit) { $null=Read-Host 'Press Enter to close' }
    }
}
exit $exitCode
