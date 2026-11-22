#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^COM[1-9][0-9]*$')][string]$Port,
    [Parameter(Mandatory)][string]$Archive
)

$ErrorActionPreference = 'Stop'
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$digest = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
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

$stream = [IO.File]::OpenRead($archivePath)
$hasher = [Security.Cryptography.SHA256]::Create()
try {
    $serial.Open()
    $serial.Write("`n")
    $work = Invoke-Reader @'
test -f /sys/firmware/devicetree/base/chosen/pb626,emmc-backup && test "$(stat -f -c %T /run)" = tmpfs && mktemp -d /run/pb626-axf.XXXXXX
'@ | Where-Object { $_ -cmatch '^/run/pb626-axf\.[A-Za-z0-9]+$' }
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
    Invoke-Reader "cd '$work' && echo '$digest  kit.tar' | sha256sum -c - && tar -xf kit.tar && rm kit.tar && sha256sum -c SHA256SUMS"
    Write-Output "Kit is ready in $work"
} finally {
    Write-Progress -Activity 'Sending kit to FEL RAM' -Completed
    $hasher.Dispose()
    $stream.Dispose()
    $serial.Dispose()
}
