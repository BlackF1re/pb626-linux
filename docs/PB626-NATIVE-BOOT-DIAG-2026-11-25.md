# Native boot diagnosis, 25 November 2026

Run 45485842757 installed p1 successfully. Power-only boot had no observed
LED/USB/Desktop. The current p2 dump is valid FAT16, both FATs equal; all 29
unchanged stock files match the original image. Active linux.ini is exactly
the expected 313 bytes, SHA256 aaf956d873cadf1df0843d4bd54de798bbfe333d0936ce07c7bb3cdcf5ea4115.
pb626.bin (7625180 bytes) is identical to artifact 14963657449, SHA256
b92a63705ed9224c00fc6a95b5f269cdd5662b1787dd1d805e86075367f824aa.
The embedded zImage and DTB are exact matches. The old payload occupies
five extents. AXF does not check fread's returned byte count; a short read
is a hypothesis, not established hardware failure. p1's latest direct FEL
root boot is not yet documented. No exact failing instruction is known.

## Non-destructive next build

Use the new artifact with Install-PB626.ps1 -UpdateBootOnly (not -EraseP1).
It checks existing p1 using e2fsck and file hashes on a read-only, noload
mount. It stages a separate pb626v2.bin, checks byte identity and verifies
a single FAT16 extent before activating linux.ini. Previous pb626.bin,
linux.ini.v1 and linux.ini.factory are retained. If any check fails, stop.
Do not remove or reformat p1, do not change BT0/BT1, VCOM or waveforms.

The assembly checks the in-RAM source and destination kernel/DTB word
hashes; kernel and DTB on disk are unchanged. AXP209 data buffer 0x0e is
the previously tested diagnostic register. Trace is bounded, idle TWI0 only;
lack of a marker is not proof that code did not run.

| Value | Meaning |
|---|---|
| 0x80 | Sentinel set/read back from working FEL Linux before cold test |
| 0x81 | Wrapper entered |
| 0x82 | CPU mode/state accepted, independent stack installed |
| 0x83 | Source kernel and DTB hashes passed |
| 0x84 | Destination hashes passed, about to enter zImage |
| 0x85 | First instruction of zImage reached (RAM trampoline; restores NOP) |
| 0x8c | Destination memory hash mismatch |
| 0x8d | Source memory hash mismatch or unexpected entry word |
| 0x8e | SCTLR.M or C remained set; stopped without unsafe handoff |

After the update, use the working USB installer shell before power off:
set marker 0x80 in AXP209 data buffer using the previously tested
i2cset -y -f 0 0x34 0x0e 0x80, then verify i2cget. On failed cold boot,
enter FEL manually and read the same register using the known working
RAM rescue; do not set it again before reading it. The updated installer includes i2cget and i2cset; the known full RAM rescue
can also read the marker after the failure. Confirm bus
identity and register before using the old commands. No other PMIC
registers should be changed. 0x85 proves entry, not decompression or PID 1.
If 0x85 is reached but Linux remains silent, test the exact same zImage,
DTB and p1 via FEL; then instrument the decompressor/kernel or use UART.
