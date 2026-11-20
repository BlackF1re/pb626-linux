# pb626-linux

Linux port for PocketBook 626 Plus / Touch Lux 3, with a lightweight
touch-oriented E Ink interface.

The initial phase is **hardware identification**, not firmware replacement.
Device revisions may differ in boot storage, touchscreen controller, frontlight
and E Ink waveform data. Nothing in this repository is currently a bootable
image or a verified replacement for the stock firmware.

## Goals

- Maintain a modern ARM Linux kernel and a compact general-purpose userland.
- Provide touchscreen-first navigation, terminal and E Ink-aware rendering.
- Support Wi-Fi, input devices, frontlight, USB, battery and suspend.
- Produce reproducible build artifacts with clear hardware validation gates.
- Preserve a tested return path to the original firmware.

## First step: read-only inventory

The factory firmware can be inspected through KOReader SSH without installing
new software on the reader. From Windows PowerShell, no local compiler, WSL or
Git checkout is required:

```powershell
Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/BlackF1re/pb626-linux/main/scripts/probe-device.sh" `
  -OutFile "$env:TEMP\probe-device.sh"

cmd /c 'ssh -p 2222 reader@READER_IP sh -s < %TEMP%\probe-device.sh > %USERPROFILE%\pocketbook-hardware.txt'
```

The probe is sent over SSH standard input. It does not need to be copied
onto the reader. The `cmd /c` step preserves the downloaded script's Unix
line endings; piping `Get-Content` into the Windows OpenSSH client can
introduce CRLF characters and cause BusyBox `sh` to report `: not found`.
The report is saved to `%USERPROFILE%\pocketbook-hardware.txt`.

For a Linux workstation, the equivalent is:

```sh
git clone https://github.com/BlackF1re/pb626-linux.git
cd pb626-linux
ssh -p 2222 reader@READER_IP 'sh -s' < scripts/probe-device.sh > pocketbook-hardware.txt
```

Replace `READER_IP` with the reader's address. The SSH account and port may
differ from KOReader defaults. The script reads procfs/sysfs and prints a
report to standard output. It does not modify the reader. The text report is
created on the computer, not on the reader.

Review the report before sharing it. It intentionally excludes serial numbers,
network addresses, storage identifiers and kernel logs. An unprivileged shell
may not be able to inspect every device; blank sections are not proof that
hardware is absent.

For a local fixture test:

```sh
sh tests/probe-smoke.sh
```

## Current status

| Component | State |
| --- | --- |
| Board revision inventory | Initial stock-firmware inventory complete; PCB ID pending |
| Boot media backup | MMC/eMMC boot areas observed; backup not performed |
| Kernel build | Not configured |
| Root filesystem | Not configured |
| E Ink bridge | Not implemented |
| Touch-oriented shell | Not implemented |
| Hardware acceptance tests | Pending |

See the [observed hardware profile](docs/HARDWARE-PROFILE.md) and
[hardware validation](docs/HARDWARE-VALIDATION.md) for the acceptance
matrix and recovery requirements. No firmware flash or storage write is
performed by CI.
