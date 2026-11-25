function Invoke-Device {
    param(
        [string]$Command,
        [byte[]]$Payload = @(),
        [int]$TimeoutSeconds = 45,
        [string]$Activity = '',
        [int]$Total = 0
    )

    $marker = 'PB626_' + [guid]::NewGuid().ToString('N')
    $serial.Write("$Command; printf '\n$marker=%s\n' `$?`n")
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $history = [Collections.Generic.List[string]]::new()
    $sent = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $nextUpdate = 0

    try {
        while ([datetime]::UtcNow -lt $deadline) {
            try {
                $line = $serial.ReadLine().Trim()
            } catch [TimeoutException] {
                continue
            }
            if ($line -ceq 'PB626_READY') {
                if (!$Payload.Length -or $sent) { throw 'Unexpected request for binary data.' }
                for ($offset = 0; $offset -lt $Payload.Length; $offset += 64KB) {
                    $length = [Math]::Min(64KB, $Payload.Length - $offset)
                    $serial.Write($Payload, $offset, $length)
                }
                $sent = $true
                continue
            }
            if ($line -match "^$marker=(\d+)$") {
                if ($Matches[1] -ne '0' -or ($Payload.Length -and !$sent)) {
                    $tail = $history | Select-Object -Last 8
                    throw "Device command failed: $Command`n$($tail -join "`n")"
                }
                return $history.ToArray()
            }
            if ($line) { $history.Add($line) }
            if ($Total -gt 0 -and $line -match '^(BLOCK|PROGRESS) (\d+)(?: |$)') {
                $done = [int]$Matches[2]
                if ($Matches[1] -eq 'BLOCK') { $done++ }
                if ($done -gt 0 -and $done -le $Total -and
                    ($timer.Elapsed.TotalSeconds -ge $nextUpdate -or $done -eq $Total)) {
                    $nextUpdate = $timer.Elapsed.TotalSeconds + 1
                    $remaining = [int]($timer.Elapsed.TotalSeconds * ($Total - $done) / $done)
                    Write-Progress -Activity $Activity -Status "$($done * 4) / $($Total * 4) MiB" `
                        -PercentComplete (100 * $done / $Total) -SecondsRemaining $remaining
                }
            }
        }
        throw "Timed out waiting for the device: $Command"
    } finally {
        if ($Total -gt 0) { Write-Progress -Activity $Activity -Completed }
    }
}

