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
    $sent = $false
    while ([datetime]::UtcNow -lt $deadline) {
        try { $line = $serial.ReadLine().Trim() } catch [TimeoutException] { continue }
        if ($line -ceq 'PB626_READY') {
            if ($sent -or !$Count) { throw 'Unexpected data request from the reader.' }
            for ($offset = 0; $offset -lt $Count; $offset += 64KB) {
                $serial.Write($Payload, $offset, [Math]::Min(64KB, $Count - $offset))
            }
            $sent = $true
        } elseif ($line -match "^$marker=(\d+)$") {
            if ($Matches[1] -ne '0' -or ($Count -and !$sent)) {
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
try {
    $serial.Open()
    $serial.Write("`n")
    $work = Invoke-Reader @'
test -f /sys/firmware/devicetree/base/chosen/pb626,emmc-backup && test "$(stat -f -c %T /run)" = tmpfs && mktemp -d /run/pb626-axf.XXXXXX
'@ | Where-Object { $_ -cmatch '^/run/pb626-axf\.[A-Za-z0-9]+$' }
    if (@($work).Count -ne 1) { throw 'Could not create a directory in FEL RAM.' }

    $buffer = [byte[]]::new(1MB)
    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $receive = @'
( old=$(stty -g) && trap 'stty "$old"' EXIT && stty raw -echo && printf '\nPB626_READY\n' && timeout 35 head -c __COUNT__ >>__WORK__/kit.tar )
'@
        $null = Invoke-Reader ($receive.Replace('__COUNT__', "$count").Replace('__WORK__', $work)) $buffer $count
        Write-Progress -Activity 'Sending kit to FEL RAM' -PercentComplete (100 * $stream.Position / $stream.Length)
    }
    Invoke-Reader "cd '$work' && echo '$digest  kit.tar' | sha256sum -c - && tar -xf kit.tar && rm kit.tar && sha256sum -c SHA256SUMS"
    Write-Output "Kit is ready in $work"
} finally {
    Write-Progress -Activity 'Sending kit to FEL RAM' -Completed
    $stream.Dispose()
    $serial.Dispose()
}
