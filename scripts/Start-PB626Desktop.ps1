#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^COM[1-9][0-9]*$')][string]$Port,
    [Parameter(Mandatory)][string]$BundleDir,
    [Parameter(Mandatory)][string]$Waveform,
    [switch]$UseMountedApps
)

$ErrorActionPreference = 'Stop'
$bundle = (Resolve-Path -LiteralPath $BundleDir).Path
$waveformPath = (Resolve-Path -LiteralPath $Waveform).Path
$waveformName = Split-Path -Leaf $waveformPath
if ($waveformName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.wbf$') { throw 'Invalid waveform filename.' }
$rootName = 'pb626-desktop-root.cpio.gz'
$rootHash = (Get-FileHash -LiteralPath (Join-Path $bundle $rootName) -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-Content -LiteralPath (Join-Path $bundle 'SHA256SUMS')) -cnotcontains "$rootHash  $rootName") {
    throw 'The desktop archive failed SHA256 verification.'
}
$waveformHash = (Get-FileHash -LiteralPath $waveformPath -Algorithm SHA256).Hash.ToLowerInvariant()
$archivePath = Join-Path ([IO.Path]::GetTempPath()) ('pb626-desktop-' + [guid]::NewGuid().ToString('N') + '.tar')
$serial = [IO.Ports.SerialPort]::new($Port, 115200)
$serial.ReadTimeout = 1000
$serial.WriteTimeout = 15000
$serial.DtrEnable = $true
$serial.RtsEnable = $true

function Invoke-Reader([string]$Command, [byte[]]$Payload = @(), [int]$Count = 0) {
    $marker = 'AXF_' + [guid]::NewGuid().ToString('N')
    $serial.Write("$Command; printf '\n$marker=%s\n' `$?`n")
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    $lines = [Collections.Generic.List[string]]::new()
    $sent = 0
    while ([datetime]::UtcNow -lt $deadline) {
        try { $line = $serial.ReadLine().Trim() } catch [TimeoutException] { continue }
        if ($line -ceq 'PB626_READY') {
            if ($sent -ge $Count) { throw 'Unexpected data request from the reader.' }
            $size = [Math]::Min(4096, $Count - $sent)
            $serial.Write($Payload, $sent, $size)
            $sent += $size
        } elseif ($line -match "^$marker=(\d+)$") {
            if ($Matches[1] -ne '0' -or $sent -ne $Count) {
                throw "Reader command failed. $($lines -join [Environment]::NewLine)"
            }
            return $lines.ToArray()
        } else {
            $lines.Add($line)
        }
    }
    throw 'Timed out waiting for the reader.'
}

$stream = $null
$hasher = [Security.Cryptography.SHA256]::Create()
try {
    & tar.exe -cf $archivePath -C $bundle $rootName -C (Split-Path -Parent $waveformPath) $waveformName
    if ($LASTEXITCODE -ne 0) { throw 'Failed to package the desktop files.' }
    $digest = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $stream = [IO.File]::OpenRead($archivePath)
    $serial.Open()
    $serial.Write("`n")
    $storageCheck = 'set -- /sys/block/mmcblk* && test ! -e "$1"'
    if ($UseMountedApps) {
        $storageCheck = 'mountpoint -q /mnt/pb626-apps && test -x /mnt/pb626-apps/bin/pb626-settings'
    }
    $check = 'test -f /sys/firmware/devicetree/base/chosen/pb626,display-bringup && test "$(stat -f -c %T /run)" = tmpfs && test ! -d /run/pb626-desktop'
    $work = Invoke-Reader "$check && $storageCheck && mktemp -d /run/pb626-gui.XXXXXX" |
        Where-Object { $_ -cmatch '^/run/pb626-gui\.[A-Za-z0-9]+$' }
    if (@($work).Count -ne 1) { throw 'Could not create a directory in FEL RAM.' }

    $buffer = [byte[]]::new(1MB)
    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $packet = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($buffer, 0, $count))
        $packetHash = [Convert]::ToHexString($hasher.ComputeHash($buffer, 0, $count)).ToLowerInvariant()
        $receive = @'
( set -e; cd '__WORK__'; old=$(stty -g); trap 'stty "$old"' EXIT; stty raw -echo;
  remaining=__COUNT__; while [ "$remaining" -gt 0 ]; do
    size=4096; if [ "$remaining" -lt "$size" ]; then size=$remaining; fi;
    printf '\nPB626_READY\n' >&2; timeout 15 head -c "$size" || exit 1;
    remaining=$((remaining - size)); done >packet.b64;
  base64 -d packet.b64 >packet; echo '__HASH__  packet' | sha256sum -c -;
  cat packet >>kit.tar; rm packet.b64 packet )
'@
        $command = $receive.Replace([string][char]13, '').Replace([string][char]10, ' ').
            Replace('__COUNT__', "$($packet.Length)").Replace('__HASH__', $packetHash).Replace('__WORK__', $work)
        $null = Invoke-Reader $command $packet $packet.Length
        Write-Progress -Activity 'Sending kit to FEL RAM' -PercentComplete (100 * $stream.Position / $stream.Length)
    }
    $null = Invoke-Reader "cd '$work' && echo '$digest  kit.tar' | sha256sum -c - && tar -xf kit.tar && rm kit.tar && echo '$rootHash  $rootName' | sha256sum -c - && echo '$waveformHash  $waveformName' | sha256sum -c -"
    $launch = @'
( set -e; set -o pipefail; cd '__WORK__'; mkdir root; gzip -dc __ROOT__ | (cd root && cpio -id --quiet); rm __ROOT__;
  for fs in dev dev/pts proc sys run; do mount -o bind "/$fs" "root/$fs"; done;
  __APPS_MOUNT__;
  setsid chroot root /usr/bin/pb626-desktop '__WORK__/__WBF__' </dev/null >/run/pb626-desktop.log 2>&1 &
  for second in $(seq 1 35); do test -s /run/pb626-desktop/ready && exit 0; sleep 1; done;
  cat /run/pb626-desktop.log; exit 1 )
'@
    $appsMount = ':'
    if ($UseMountedApps) {
        $appsMount = 'mkdir -p root/mnt/pb626-apps && mount -o bind /mnt/pb626-apps root/mnt/pb626-apps && mount -o remount,bind,ro root/mnt/pb626-apps'
    }
    $launch = $launch.Replace([string][char]13, '').Replace([string][char]10, ' ').
        Replace('__APPS_MOUNT__', $appsMount).
        Replace('__WORK__', $work).Replace('__ROOT__', $rootName).Replace('__WBF__', $waveformName)
    $null = Invoke-Reader $launch
    Write-Output "PocketBook desktop started in RAM. USB console port is $Port."
} finally {
    Write-Progress -Activity 'Sending kit to FEL RAM' -Completed
    $hasher.Dispose()
    if ($stream) { $stream.Dispose() }
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath }
    $serial.Dispose()
}
