#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^(COM[1-9][0-9]*|/dev/ttyACM[0-9]+)$')][string]$Port,
    [Parameter(Mandatory)][string]$BackupDir,
    [switch]$Raw,
    [switch]$SD
)
$ErrorActionPreference = 'Stop'
$blockSize = 4MB
$remote = '/bin/sh /run/pb626-restore-fast.sh'
$images = @(
    @{ Region = 'user'; Name = 'pb626-emmc-user.img'; Blocks = 1864 }
    @{ Region = 'boot0'; Name = 'pb626-emmc-boot0.img'; Blocks = 1 }
    @{ Region = 'boot1'; Name = 'pb626-emmc-boot1.img'; Blocks = 1 }
)
if (Test-Path -LiteralPath $BackupDir) { throw 'Choose a new backup directory; existing data is never overwritten.' }
$dest = (New-Item -ItemType Directory -Path $BackupDir).FullName
$serial = [IO.Ports.SerialPort]::new($Port, 115200)
$serial.ReadTimeout = 1000
$serial.WriteTimeout = 15000
$serial.DtrEnable = $true
$serial.RtsEnable = $true
$buffer = [byte[]]::new($blockSize)
$wireBuffer = [byte[]]::new($blockSize)
function Invoke-Device {
    param([string]$Command, [switch]$Receive, [int]$TimeoutSeconds = 60, [int]$ExpectedBytes = $blockSize)
    $marker = 'PB626_' + [guid]::NewGuid().ToString('N')
    $serial.Write("$Command; printf '\n$marker=%s\n' `$?`n")
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $history = [Collections.Generic.List[string]]::new()
    $received = $false
    $endSeen = $false
    while ([datetime]::UtcNow -lt $deadline) {
        try { $line = $serial.ReadLine().Trim() } catch [TimeoutException] { continue }
        if ($line -cmatch '^PB626_DATA ([0-9]+) ([a-f0-9]{64})(?: (raw|gzip|zero))?$') {
            $bytes = [long]$Matches[1]
            $want = $Matches[2]
            $format = if ($Matches.ContainsKey(3)) { $Matches[3] } else { 'raw' }
            if (!$Receive -or $received -or $bytes -gt $ExpectedBytes -or
                ($format -eq 'raw' -and $bytes -ne $ExpectedBytes) -or
                ($format -eq 'gzip' -and ($bytes -le 0 -or $bytes -ge $ExpectedBytes)) -or
                ($format -eq 'zero' -and $bytes -ne 0)) {
                throw 'Unexpected binary header; power off and restart the RAM recovery session.'
            }
            # Keep the original byte[] object (PowerShell can enumerate arrays
            # when assigning the output of an if-expression).
            if ($format -eq 'raw') { $dest = $buffer } else { $dest = $wireBuffer }
            $offset = 0
            while ($offset -lt $bytes) {
                if ([datetime]::UtcNow -ge $deadline) { throw 'Binary receive timed out.' }
                try {
                    $n = $serial.Read($dest, $offset, [Math]::Min(64KB, [int]($bytes - $offset)))
                } catch [TimeoutException] { continue }
                $offset += $n
            }
            if ($format -eq 'zero') {
                [Array]::Clear($buffer, 0, $ExpectedBytes)
            } elseif ($format -eq 'gzip') {
                $encodedBlock = [IO.MemoryStream]::new($wireBuffer, 0, [int]$bytes, $false)
                try {
                    $gzip = [IO.Compression.GZipStream]::new($encodedBlock, [IO.Compression.CompressionMode]::Decompress, $true)
                    try {
                        $gzip.ReadExactly($buffer, 0, $ExpectedBytes)
                        if ($gzip.ReadByte() -ne -1) { throw 'Oversized compressed block.' }
                    } finally { $gzip.Dispose() }
                } finally { $encodedBlock.Dispose() }
            }
            $hashBlock = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            try {
                $hashBlock.AppendData($buffer,0,$ExpectedBytes)
                $actual = [Convert]::ToHexString($hashBlock.GetHashAndReset())
            } finally { $hashBlock.Dispose() }
            if ($actual -ne $want) { throw 'Binary backup block checksum mismatch.' }
            $received = $true
        } elseif ($line -ceq 'PB626_DATA_END') {
            if (!$received -or $endSeen) { throw 'Unexpected binary end marker.' }
            $endSeen = $true
        } elseif ($line -match "^$marker=(\d+)$") {
            if ($Matches[1] -ne '0' -or ($Receive -and (!$received -or !$endSeen))) {
                throw "Device command failed: $Command`n$($history -join "`n")"
            }
            return $history.ToArray()
        } elseif ($line) { $history.Add($line) }
    }
    throw "Device command timed out: $Command"
}
try {
    $serial.Open()
    $serial.Write("`n")
    $code = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'pb626-restore-fast.sh')).Replace("`r",'')
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($code))
    $null = Invoke-Device ': > /run/pb626-restore-fast.sh.b64'
    for ($offset = 0; $offset -lt $encoded.Length; $offset += 1024) {
        $part = $encoded.Substring($offset, [Math]::Min(1024, $encoded.Length - $offset))
        $null = Invoke-Device "printf '%s' '$part' >> /run/pb626-restore-fast.sh.b64"
    }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($code))).ToLowerInvariant()
    $null = Invoke-Device "base64 -d /run/pb626-restore-fast.sh.b64 > /run/pb626-restore-fast.sh && echo '$hash  /run/pb626-restore-fast.sh' | sha256sum -c -"
    $info = @(Invoke-Device "$remote $(if ($SD) {'sd-info'} else {'backup-info'})")
    $ids = @($info | Where-Object { $_ -cmatch '^CID=[a-f0-9]{32}$' })
    if ($ids.Count -ne 1) { throw 'Invalid recovery device CID.' }
    $cid = $ids[0].Substring(4)
    $probeCommand = "$remote probe"
    if ($SD) {
        $sizes = @($info | Where-Object { $_ -cmatch '^SECTORS=[0-9]+$' })
        if ($sizes.Count -ne 1) { throw 'Invalid SD geometry' }
        $sectors = [long]$sizes[0].Substring(8)
        if ($sectors -lt 1 -or $sectors -gt 2147483648) { throw 'Unsupported SD capacity' }
        $size = $sectors * 512
        $blocks = [int][Math]::Ceiling($size / $blockSize)
        $images = @(@{Region='sd'; Name='pb626-sd.img'; Blocks=$blocks; Bytes=$size})
        $probeCommand = "$remote sd-info"
        $remote = "PB626_SD_CID=$cid PB626_SD_SECTORS=$sectors $remote"
        [IO.File]::WriteAllText((Join-Path $dest 'pb626-sd-cid.txt'), "$cid`n")
        $metadata = @('pb626-sd-cid.txt')
    } else {
        $exts = @($info | Where-Object { $_ -match '^EXT_CSD=[0-9a-f]{1024}$' })
        if ($exts.Count -ne 1) { throw 'Invalid EXT_CSD.' }
        [IO.File]::WriteAllText((Join-Path $dest 'pb626-emmc-cid.txt'), "$cid`n")
        [IO.File]::WriteAllBytes((Join-Path $dest 'pb626-emmc-ext-csd.bin'), [Convert]::FromHexString($exts[0].Substring(8)))
        $metadata = @('pb626-emmc-ext-csd.bin','pb626-emmc-cid.txt')
        foreach ($image in $images) { $image.Bytes = [long]$image.Blocks * $blockSize }
    }
    $readOperation = if ($Raw) { 'backup-read' } else { 'backup-read-packed' }
    foreach ($image in $images) {
        $path = Join-Path $dest $image.Name
        $stream = [IO.File]::Open($path + '.partial', [IO.FileMode]::CreateNew)
        try {
            for ($i = 0; $i -lt $image.Blocks; $i++) {
                $length = [int][Math]::Min([long]$blockSize, $image.Bytes - [long]$i * $blockSize)
                $null = Invoke-Device "$remote $readOperation $($image.Region) $i" -Receive -ExpectedBytes $length -TimeoutSeconds 180
                $stream.Write($buffer, 0, $length)
                Write-Progress -Activity "Backing up $($image.Region)" -PercentComplete (100 * ($i + 1) / $image.Blocks)
            }
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
            Write-Progress -Activity "Backing up $($image.Region)" -Completed
        }
        $actual = (Get-FileHash -LiteralPath ($path + '.partial')).Hash
        $lines = @(Invoke-Device "$remote backup-hash $($image.Region)" -TimeoutSeconds 3600 | Where-Object { $_ -cmatch '^SHA256 [a-f0-9]{64}$' })
        if ($lines.Count -ne 1 -or $actual -ne $lines[0].Substring(7)) {
            throw "Full device readback mismatch: $($image.Region)"
        }
        Move-Item -LiteralPath ($path + '.partial') -Destination $path
    }
    if ((Invoke-Device $probeCommand) -notcontains "CID=$cid") { throw 'Final device identity check failed.' }
    $names = @($images | ForEach-Object { $_.Name }) + $metadata
    $manifest = foreach ($name in $names) {
        "$((Get-FileHash -LiteralPath (Join-Path $dest $name)).Hash.ToLowerInvariant())  $name"
    }
    Set-Content -LiteralPath (Join-Path $dest 'SHA256SUMS') -Value $manifest -Encoding ascii
    Write-Host 'All selected regions backed up and verified. Keep the entire directory private.'
} finally { $serial.Dispose() }
