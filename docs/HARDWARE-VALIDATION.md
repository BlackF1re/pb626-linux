# Hardware validation

This document records device-specific evidence. Support is not assumed from a
model name, upstream device tree or a successful cross-compile.

## Initial acceptance criteria

| Subsystem | Evidence required | Status |
| --- | --- | --- |
| SoC and RAM | Kernel, CPU and memory inventory | Pending |
| Boot storage | Storage topology and verified full backup | Pending |
| Bootloader | Non-destructive boot handoff and recovery route | Pending |
| E Ink | Full and partial updates; waveform provenance | Pending |
| Touchscreen | Controller identification and coordinate mapping | Pending |
| Frontlight | Brightness range, off state and resume | Pending |
| Buttons | Linux input events and wake behavior | Pending |
| Wi-Fi | Driver, association and reconnect after suspend | Pending |
| Power | Charge state, battery capacity and shutdown | Pending |
| USB | Mode identification and data transfer | Pending |
| Suspend | Repeated sleep/wake cycles without display corruption | Pending |

## Hardware inspection

Run the read-only inventory under the factory firmware before preparing boot
media. It deliberately skips MAC addresses, serial numbers, MMC CID/CSD and
kernel logs. Review its output before uploading it or posting it publicly.

The initial probe only reads files from procfs and sysfs. It neither accesses
raw block contents nor changes partitions, firmware, networking or boot state.

The probe can run under an unprivileged KOReader SSH shell. Missing items
must be recorded as inaccessible rather than inferred absent. Root privileges
are not required for the first pass.

## Destructive-operation boundary

Do not overwrite, repartition or replace the original boot media during
inventory or initial build work. Before a real boot experiment:

1. Identify the physical storage type and board revision.
2. Create and verify an offline full-device backup using the correct storage
   method; a user-visible USB volume is not a full firmware backup.
3. Identify a viable recovery interface, preferably UART.
4. Confirm the selected device tree, boot image format and display waveforms.
5. Test on separate media where the hardware actually permits it.

The presence of a removable microSD is not presumed for every 626 variant.
