# Windows PowerShell 5.1+; close PuTTY before running.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BundleDir,
    [Parameter(Mandatory=$true)][string]$FactoryBackupDir,
    [string]$Distro='XperiaDev',
    [switch]$EraseP1,
    [switch]$UpdateBootOnly
)
$ErrorActionPreference='Stop'
if ($EraseP1.IsPresent -eq $UpdateBootOnly.IsPresent) { throw 'Choose exactly one: -EraseP1 or -UpdateBootOnly' }
$mode = if ($UpdateBootOnly) { '--update-boot' } else { '--erase-p1' }
$bundle=(Resolve-Path -LiteralPath $BundleDir).Path
$backup=(Resolve-Path -LiteralPath $FactoryBackupDir).Path
foreach ($item in @(
    @{Name='pb626-emmc-user.img'; Length=7818182656L},
    @{Name='pb626-emmc-boot0.img'; Length=4194304L},
    @{Name='pb626-emmc-boot1.img'; Length=4194304L}
)) {
    $f=Get-Item -LiteralPath (Join-Path $backup $item.Name)
    if ($f.Length -ne $item.Length) { throw "Invalid factory backup size: $($item.Name)" }
    if ($item.Name -ne 'pb626-emmc-user.img') {
        if ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne 'bb9f8df61474d25e71fa00722318cd387396ca1736605e1248821cc0de3d3af8') {
            throw "Unexpected hardware boot region backup: $($item.Name)"
        }
    }
}
$info=Get-Content -Raw -LiteralPath (Join-Path $backup 'emmc-info.txt')
if ($info -notmatch '(?i)\bCID\s+([0-9a-f]{32})\b') { throw 'Missing expected CID in emmc-info.txt' }
$cid=$Matches[1].ToLowerInvariant()
# Check the critical original loader bytes in the offline backup, not its name.
$fs=[IO.File]::OpenRead((Join-Path $backup 'pb626-emmc-user.img'))
try {
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        foreach ($region in @(
            @{Offset=0x2000; Count=0x5400; SHA='245b81edb1f1ffa51738f33548f793500f2fab9b00c150df9f1ee78b81667824'},
            @{Offset=0x012a6000; Count=0x38000; SHA='3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227'},
            @{Offset=0x012e6000; Count=0x38000; SHA='3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227'},
            @{Offset=0x02400000; Count=0x02000000; SHA='237dd3c9930c9257a40652d7b4d5427d804748a865653f821551400fa075a21e'}
        )) {
            $null=$fs.Seek($region.Offset,[IO.SeekOrigin]::Begin)
            $buf=New-Object byte[] $region.Count
            $n=0
            while ($n -lt $buf.Length) {
                $k=$fs.Read($buf,$n,$buf.Length-$n)
                if ($k -eq 0) { throw 'Unexpected end of backup' }
                $n+=$k
            }
            $digest=[BitConverter]::ToString($hash.ComputeHash($buf)).Replace('-','').ToLowerInvariant()
            if ($digest -cne $region.SHA) { throw 'Backup does not contain the expected original boot chain' }
        }
    } finally { $hash.Dispose() }
} finally { $fs.Dispose() }
foreach ($line in Get-Content -LiteralPath (Join-Path $bundle 'SHA256SUMS')) {
    if ($line -notmatch '^([0-9a-f]{64})  ([A-Za-z0-9_.-]+)$') { throw "Malformed checksum line: $line" }
    $expected=$Matches[1]; $name=$Matches[2]
    if ((Get-FileHash -LiteralPath (Join-Path $bundle $name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) {
        throw "Artifact checksum mismatch: $name"
    }
}
if ($UpdateBootOnly) { Write-Host 'Boot-only update; p1 will be verified read-only.' }
else { Write-Host 'p1 will be erased; backups and target CID will be checked.' }
Write-Host 'Disconnect other PocketBooks.'
& (Join-Path $PSScriptRoot 'Start-PB626.ps1') -BundleDir $bundle -Variant elan-emmc-install -Profile diagnostic -Distro $Distro
# Wait for the dedicated installer USB console. Do not send anything if ambiguous.
$deadline=[DateTime]::UtcNow.AddMinutes(3)
$port=$null
do {
    $ports=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match 'VID_0525&PID_A4A7' -and $_.FriendlyName -match '\(COM[1-9][0-9]*\)'
    })
    if ($ports.Count -gt 1) { throw 'More than one matching ACM device' }
    if ($ports.Count -eq 1) {
        $port=[regex]::Match($ports[0].FriendlyName,'COM[1-9][0-9]*').Value
        break
    }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $port) { throw 'Installer ACM console did not enumerate; no installation command was sent' }
$serial=[IO.Ports.SerialPort]::new($port,115200)
$serial.ReadTimeout=1000
$serial.WriteTimeout=10000
$serial.DtrEnable=$true
$serial.RtsEnable=$true
$nl=[string][char]10
try {
    $serial.Open()
    $serial.Write($nl)
    Start-Sleep -Seconds 2
    # The shell prints a unique marker only AFTER the command has exited.
    $tag='PB626_DONE_'+[Guid]::NewGuid().ToString('N')
    $command="install-pb626-emmc $mode $cid; printf '\n$tag=%s\n' "+'$?'
    $serial.Write($command+$nl)
    $deadline=[DateTime]::UtcNow.AddMinutes(45)
    $complete=$false
    while ([DateTime]::UtcNow -lt $deadline) {
        try { $line=$serial.ReadLine().Trim() } catch [TimeoutException] { continue }
        Write-Host $line
        if ($line -ceq 'PB626 INSTALL COMPLETE') { $complete=$true }
        if ($line -match "^$tag=(\d+)$") {
            if ($Matches[1] -ne '0' -or -not $complete) { throw 'Installation failed; do not assume a bootable system' }
            Write-Host 'Installation verified. Disconnect USB and fully power off, then press Power normally.'
            return
        }
    }
    throw 'Timed out waiting for installer result; do not interrupt a live write or assume success'
} finally { $serial.Dispose() }
