#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw "This test must run in Windows PowerShell 5.1; got $($PSVersionTable.PSVersion)."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'scripts\installer\PB626.ps1'
$launcher = Join-Path $repoRoot 'scripts\Start-PB626.ps1'
$cmdFile = Join-Path $repoRoot 'scripts\installer\PB626.cmd'

foreach ($path in @($installer, $launcher)) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$parseErrors
    )
    if ($parseErrors.Count) {
        throw "PowerShell 5.1 parser errors in $path : $($parseErrors -join '; ')"
    }
}

$installerText = [IO.File]::ReadAllText($installer)
if ($installerText -match '\$IsWindows|\$IsLinux|#Requires\s+-Version\s+7') {
    throw 'The Windows installer still depends on PowerShell 6+/7 automatic variables or version requirements.'
}
if ($installerText -notmatch '#Requires\s+-Version\s+5\.1') {
    throw 'The installer must explicitly require Windows PowerShell 5.1 or newer.'
}
$cmdText = [IO.File]::ReadAllText($cmdFile)
if ($cmdText -notmatch 'powershell\.exe' -or $cmdText -match 'pwsh\.exe') {
    throw 'PB626.cmd must launch the built-in Windows PowerShell, not pwsh.'
}

# Exercise the package validator in this actual Windows PowerShell 5.1 process.
# The fixture has the same required layout as the public kit but no device data.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('pb626-ps51-' + [guid]::NewGuid().ToString('N'))
try {
    $paths = @(
        'dump-network.py',
        'install-direct.py',
        'native\BUILD-COMMIT',
        'native\SHA256SUMS',
        'native\pb626-rootfs.ext4.gz',
        'native\pb626-rootfs.bmap.json',
        'native\pb626-bt0-menu.raw',
        'recovery\BUILD-COMMIT',
        'recovery\fel-boot.sh',
        'recovery\Start-PB626.ps1',
        'recovery\SHA256SUMS',
        'tools\Backup-PB626Fast.ps1',
        'tools\Restore-PB626Fast.ps1',
        'tools\SHA256SUMS.fast',
        'tools\pb626-restore-fast.sh',
        'tools\pb626-restore-scan.gz',
        'source\scripts\prepare-install.sh',
        'fel-host\SHA256SUMS'
    )
    foreach ($relative in $paths) {
        $target = Join-Path $temp $relative
        $directory = Split-Path -Parent $target
        if (!(Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        if ($relative -eq 'native\BUILD-COMMIT' -or $relative -eq 'recovery\BUILD-COMMIT') {
            [IO.File]::WriteAllText($target, "0123456789abcdef0123456789abcdef01234567" + [Environment]::NewLine)
        } elseif ($relative -eq 'native\pb626-rootfs.bmap.json') {
            [IO.File]::WriteAllText($target, '{"version":1,"image_bytes":4194304,"chunk_bytes":4194304,"mapped":[0]}')
        } else {
            [IO.File]::WriteAllText($target, "PowerShell 5.1 fixture: $relative" + [Environment]::NewLine)
        }
    }

    Copy-Item -LiteralPath $installer -Destination (Join-Path $temp 'PB626.ps1')
    $manifestPath = Join-Path $temp 'SHA256SUMS'
    $manifestLines = @()
    foreach ($file in (Get-ChildItem -LiteralPath $temp -File -Recurse | Sort-Object FullName)) {
        if ($file.FullName -eq $manifestPath) { continue }
        $relative = $file.FullName.Substring($temp.Length + 1).Replace('\','/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestLines += "$hash  $relative"
    }
    [IO.File]::WriteAllLines($manifestPath, [string[]]$manifestLines, [Text.Encoding]::ASCII)

    & (Join-Path $temp 'PB626.ps1') -Action Validate
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Package validation returned native exit code $LASTEXITCODE."
    }
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}

Write-Host 'WINDOWS POWERSHELL 5.1 COMPATIBILITY PASS' -ForegroundColor Green
