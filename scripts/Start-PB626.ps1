# PocketBook 626 Plus / Touch Lux 3: canonical Windows -> WSL -> FEL launcher.
#
# Usage (Windows PowerShell 5.1; from the folder holding fel-boot.sh):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-PB626.ps1 `
#       -BundleDir C:\PB626\bundle -Variant elan-display -Profile standard
# Recovery: -Variant elan-emmc-backup -Profile diagnostic
#
# What it does, in order:
#   1. Verify Megi artifact paths and start the selected WSL distro (Ubuntu by default).
#   2. Discover the reader in cold-boot Allwinner FEL (1f3a:efe8), attach via
#      usbipd, and verify that WSL sees the reader.
#   3. Convert paths using /mnt/c/... WITHOUT `wslpath` quoting issues.
#   4. Run the matching Linux fel-boot.sh, which sends one known SPL, transfers
#      zImage/DTB/initramfs/entry in 64 KiB chunks and compares RAM readbacks.
#   5. Request execute, then look for 0525:a4a7 USB serial in Windows/WSL.
#
# CRITICAL: FEL execute exit 0 does NOT mean Linux booted. The diagnostic
# /init must successfully bind a USB gadget (0525:a4a7) for a COM shell.
# E Ink image and backlight cannot be used to infer a successful boot.
# The SPL, 52-byte entry stub, and *patched* sunxi-fel still reside in the
# audited /root/pb626-lab WSL directory; stock Windows sunxi-fel hangs after
# SPL because it restores the ROM MMU. No eMMC or microSD writes occur here.
# Start only after fully powering off the reader and entering FEL afresh.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BundleDir,
    [ValidateSet('elan-display','elan-emmc-backup','elan-emmc-sd-backup')][string]$Variant='elan-display',
    [ValidateSet('standard','diagnostic')][string]$Profile='standard',
    [string]$Distro='Ubuntu',
    [string]$LabDir,
    [switch]$NoExecute
)

& {
    $ErrorActionPreference='Stop'

    foreach ($cmd in @('wsl.exe','usbipd.exe')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "Missing Windows command: $cmd"
        }
    }
    $linuxScript=Join-Path $PSScriptRoot 'fel-boot.sh'
    if (-not (Test-Path -LiteralPath $linuxScript)) {
        throw "Download fel-boot.sh next to this Windows script: $linuxScript"
    }
    $resolvedBundle=(Resolve-Path -LiteralPath $BundleDir).Path
    if (-not (Test-Path -LiteralPath $resolvedBundle -PathType Container)) {
        throw "Not a bundle directory: $resolvedBundle"
    }

    function ConvertTo-WslPath([string]$WindowsPath) {
        $resolved=(Resolve-Path -LiteralPath $WindowsPath).Path
        if ($resolved -match '^([A-Za-z]):\\(.*)$') {
            $drive=$Matches[1].ToLowerInvariant()
            $tail=$Matches[2].Replace('\','/')
        } else {
            throw "Path must be on a Windows drive: $resolved"
        }
        return "/mnt/$drive/$tail"
    }
    $wslBundle=ConvertTo-WslPath $resolvedBundle
    $wslLinuxScript=ConvertTo-WslPath $linuxScript

    # This first invocation also creates the WSL VM needed by usbipd attach.
    & wsl.exe -d $Distro -u root -- true
    if ($LASTEXITCODE -ne 0) { throw "Failed to start WSL distro $Distro" }

    $felDevices=@(& usbipd.exe list | Where-Object {
        $_ -match '^\s*\d+-\d+\s+1f3a:efe8\b'
    })
    if ($felDevices.Count -ne 1) {
        throw "Expected exactly one PocketBook in cold FEL mode, found $($felDevices.Count)."
    }
    $line=$felDevices[0]
    $busid=[regex]::Match($line,'^\s*(\d+-\d+)').Groups[1].Value
    Write-Host "PocketBook FEL BUSID: $busid"
    if ($line -notmatch 'Attached\s*$') {
        if ($line -match 'Not shared\s*$') {
            & usbipd.exe bind --busid $busid
            if ($LASTEXITCODE -ne 0) {
                throw "usbipd bind failed; elevate PowerShell for a one-time bind of $busid."
            }
        }
        & usbipd.exe attach --wsl --busid $busid
        if ($LASTEXITCODE -ne 0) { throw 'usbipd attach failed' }
    }
    Start-Sleep -Seconds 2
    & wsl.exe -d $Distro -u root -- lsusb -d 1f3a:efe8
    if ($LASTEXITCODE -ne 0) { throw 'FEL device not visible from WSL' }

    $argsLinux=@($wslLinuxScript,$wslBundle,$Variant,$Profile)
    if ($NoExecute) { $argsLinux+='--no-execute' }
    Write-Host "Starting RAM-only Megi: variant=$Variant profile=$Profile"
    if ($LabDir) {
        $lab=ConvertTo-WslPath $LabDir
        & wsl.exe -d $Distro -u root -- env "PB626_LAB_DIR=$lab" "PB626_FEL_TOOL=$lab/sunxi-fel" bash @argsLinux
    } else {
        & wsl.exe -d $Distro -u root -- bash @argsLinux
    }
    $exit=$LASTEXITCODE
    Write-Host "`nFEL loader exit: $exit (NOT proof of Linux boot)"
    if ($exit -ne 0) { throw "FEL upload/verification failed: exit $exit" }

    if (-not $NoExecute) {
        # A new Linux USB device may enumerate back on Windows rather than
        # auto-attach to WSL: inspect both, never infer boot from LED/backlight.
        Write-Host "`n=== USB visible in WSL ==="
        & wsl.exe -d $Distro -u root -- lsusb
        Write-Host "`n=== usbipd devices in Windows ==="
        & usbipd.exe list
        Write-Host "`n=== Linux USB gadget (0525:a4a7) on Windows ==="
        $devices=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -match 'VID_0525&PID_A4A7'
        })
        if ($devices.Count -eq 0) {
            Write-Warning 'No USB ACM gadget detected: Linux serial console is NOT available yet.'
        } else {
            $devices | Format-Table Status,FriendlyName,InstanceId -AutoSize
            Write-Host 'Open the newly identified COM port using PuTTY, 115200 8N1.'
        }
    }
}
