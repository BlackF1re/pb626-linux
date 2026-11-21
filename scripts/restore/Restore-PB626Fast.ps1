#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^COM[1-9][0-9]*$')]
    [string]$Port,
    [string]$BackupDir = $PSScriptRoot,
    [switch]$Write,
    [switch]$AllowOtherCard
)

$ErrorActionPreference = 'Stop'
$backupCid = '1501003857504433520068d8fe0384e3'
$blockSize = 4MB
$remote = '/bin/sh /run/pb626-restore-fast.sh'
$images = @(
    @{ Region = 'user'; Name = 'pb626-emmc-user.img'; Blocks = 1864 }
    @{ Region = 'boot0'; Name = 'pb626-emmc-boot0.img'; Blocks = 1 }
    @{ Region = 'boot1'; Name = 'pb626-emmc-boot1.img'; Blocks = 1 }
)

function Read-Checksums([string]$Path) {
    $checksums = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -notmatch '^([a-fA-F0-9]{64})\s+(pb626-[a-z0-9.-]+)$' -or
            $checksums.ContainsKey($Matches[2])) {
            throw "Invalid checksum entry in $Path"
        }
        $checksums[$Matches[2]] = $Matches[1]
    }
    $checksums
}

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

function Get-Sha256([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}

function Get-ChunksToWrite($Image) {
    $lines = @(Invoke-Device "$remote scan $($Image.Region)" -TimeoutSeconds 3600 `
        -Activity "Scanning $($Image.Region)" -Total $Image.Blocks)
    $index = 0
    foreach ($line in $lines) {
        if ($line -notmatch '^BLOCK (\d+) ([a-f0-9]{64})$') { continue }
        if ([int]$Matches[1] -ne $index -or $index -ge $Image.Blocks) {
            throw "Invalid block order for $($Image.Region)."
        }
        if ($Matches[2] -ne $Image.BlockHashes[$index]) { $index }
        $index++
    }
    if ($index -ne $Image.Blocks) { throw "Incomplete scan of $($Image.Region)." }
}

function Send-ImageBlock($Image, [int]$Index, [byte[]]$Buffer) {
    $Image.Stream.Position = [long]$Index * $blockSize
    $Image.Stream.ReadExactly($Buffer, 0, $blockSize)
    $encoded = [IO.MemoryStream]::new()
    try {
        $gzip = [IO.Compression.GZipStream]::new(
            $encoded, [IO.Compression.CompressionLevel]::Fastest, $true
        )
        try {
            $gzip.Write($Buffer, 0, $Buffer.Length)
        } finally {
            $gzip.Dispose()
        }
        $format = 'raw'
        $payload = $Buffer
        if ($encoded.Length -lt $Buffer.Length) {
            $format = 'gzip'
            $payload = $encoded.ToArray()
        }
        $command = "$remote write $($Image.Region) $Index $format $($payload.Length) $($Image.BlockHashes[$Index])"
        $null = Invoke-Device $command -Payload $payload -TimeoutSeconds 180
    } finally {
        $encoded.Dispose()
    }
}

$manifest = Read-Checksums (Join-Path $BackupDir 'SHA256SUMS')
$tools = Read-Checksums (Join-Path $PSScriptRoot 'SHA256SUMS.fast')
$scannerName = 'pb626-restore-scan.gz'
$scanner = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $scannerName))
if ((Get-Sha256 $scanner) -ne $tools[$scannerName]) {
    throw 'ARM recovery helper checksum mismatch.'
}
$extName = 'pb626-emmc-ext-csd.bin'
$extPath = Join-Path $BackupDir $extName
if ((Get-Item -LiteralPath $extPath).Length -ne 512 -or
    (Get-FileHash -LiteralPath $extPath).Hash -ne $manifest[$extName]) {
    throw 'EXT_CSD snapshot checksum or size mismatch.'
}

$serial = [IO.Ports.SerialPort]::new($Port, 115200)
$buffer = [byte[]]::new($blockSize)
try {
    foreach ($image in $images) {
        $image.Stream = [IO.File]::Open(
            (Join-Path $BackupDir $image.Name), [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        if ($image.Stream.Length -ne ([long]$image.Blocks * $blockSize)) {
            throw "Unexpected image size: $($image.Name)"
        }
        Write-Host "Checking $($image.Name)..."
        $image.BlockHashes = [string[]]::new($image.Blocks)
        $full = [Security.Cryptography.IncrementalHash]::CreateHash(
            [Security.Cryptography.HashAlgorithmName]::SHA256
        )
        try {
            for ($index = 0; $index -lt $image.Blocks; $index++) {
                $image.Stream.ReadExactly($buffer, 0, $blockSize)
                $full.AppendData($buffer)
                $image.BlockHashes[$index] = Get-Sha256 $buffer
            }
            if ([Convert]::ToHexString($full.GetHashAndReset()) -ne $manifest[$image.Name]) {
                throw "Image checksum mismatch: $($image.Name)"
            }
        } finally {
            $full.Dispose()
        }
    }

    $serial.ReadTimeout = 1000
    $serial.WriteTimeout = 15000
    $serial.Open()
    $serial.Write("`n")
    $scriptPath = Join-Path $PSScriptRoot 'pb626-restore-fast.sh'
    $code = (Get-Content -Raw -LiteralPath $scriptPath).Replace("`r", '')
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($code))
    $destination = '/run/pb626-restore-fast.sh'
    $null = Invoke-Device ": > $destination.b64"
    for ($offset = 0; $offset -lt $encoded.Length; $offset += 1024) {
        $part = $encoded.Substring($offset, [Math]::Min(1024, $encoded.Length - $offset))
        $null = Invoke-Device "printf '%s' '$part' >> $destination.b64"
    }
    $null = Invoke-Device "base64 -d $destination.b64 > $destination && rm $destination.b64"
    $probe = @(Invoke-Device "$remote probe" | Where-Object { $_ -match '^CID=[a-f0-9]{32}$' })
    if ($probe.Count -ne 1) { throw 'No valid eMMC CID received.' }
    $cid = $probe[0].Substring(4)
    Write-Host "Target eMMC CID $cid"
    if ($cid -ne $backupCid -and !$AllowOtherCard) {
        throw 'Different eMMC CID. See README.md before using -AllowOtherCard.'
    }

    $null = Invoke-Device "$remote load-scanner $($scanner.Length) $($tools[$scannerName])" `
        -Payload $scanner -TimeoutSeconds 120
    [Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    $testHash = Get-Sha256 $buffer
    Write-Host 'Testing binary USB transfer of 4 MiB to RAM...'
    $test = @(Invoke-Device "$remote test-transfer $blockSize $testHash" -Payload $buffer -TimeoutSeconds 120)
    if ($test -notcontains "BLOCK 0 $testHash") { throw 'RAM transfer or scanner verification failed.' }
    $null = Invoke-Device "$remote verify boot0" -TimeoutSeconds 45
    Write-Host 'Preflight passed. No eMMC writes performed.'
    if (!$Write) { return }

    if ($cid -ne $backupCid) {
        Write-Warning 'Different eMMC. This copies the original reader data, including device-specific data.'
    }
    Write-Warning 'This overwrites the entire user area and both boot areas. Keep the USB cable connected.'
    $confirmation = "RESTORE $cid"
    if ((Read-Host "Type $confirmation to continue") -cne $confirmation) {
        throw 'Confirmation did not match. No eMMC writes performed.'
    }
    if ((Invoke-Device "$remote probe") -notcontains "CID=$cid") {
        throw 'The eMMC CID changed during preflight.'
    }

    foreach ($image in $images) {
        $region = $image.Region
        Write-Host "Scanning $region..."
        $changed = @(Get-ChunksToWrite $image)
        Write-Host "Restoring $region ($($changed.Count) of $($image.Blocks) blocks)..."
        $done = 0
        try {
            foreach ($index in $changed) {
                Send-ImageBlock $image $index $buffer
                $done++
                Write-Progress -Activity "Restoring $region" -Status "$done / $($changed.Count) blocks" `
                    -PercentComplete (100 * $done / $changed.Count)
            }
        } finally {
            Write-Progress -Activity "Restoring $region" -Completed
        }
        Write-Host "Verifying $region..."
        $verified = @(Invoke-Device "$remote verify $region" -TimeoutSeconds 3600 `
            -Activity "Verifying $region" -Total $image.Blocks)
        $digest = @($verified | Where-Object { $_ -match '^SHA256 [a-f0-9]{64}$' })
        if ($digest.Count -ne 1 -or $digest[0].Substring(7) -ne $manifest[$image.Name]) {
            throw "Readback verification failed: $region"
        }
    }
    if ((Invoke-Device "$remote probe") -notcontains "CID=$cid") {
        throw 'Final eMMC safety check failed.'
    }
    Write-Host 'All three eMMC regions match SHA256SUMS. The reader can be powered off.'
} finally {
    $serial.Dispose()
    foreach ($image in $images) {
        if ($image.Stream) { $image.Stream.Dispose() }
    }
}
