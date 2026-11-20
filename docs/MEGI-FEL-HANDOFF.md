# Megi 5.9 FEL boot: initramfs handoff and diagnostic acceptance

The existing FEL entry stub loads:
- zImage at `0x42000000`
- DTB at `0x43200000`
- compressed initramfs at `0x45000000`
- entry stub at `0x41000000`

The previous DTBs had no `/chosen/linux,initrd-start` and `linux,initrd-end` properties. This branch adds both *after* initramfs construction, using its actual byte length. A successful compile was already established, but on-device kernel boot remains unproven.

## Initial test (RAM-only)
1. Re-enter FEL after fully powering down the reader.
2. Select the newly built `pb626-elan.dtb`, `pb626-megi-zImage`, and `pb626-megi-initramfs.cpio.gz`.
3. Retain the known local `pb626-spl.bin`, `direct-entry.bin` and FEL loader, with `PB626_FEL_KEEP_MMU_OFF=1`.
4. Confirm whether USB `0525:a4a7` (Linux ACM gadget) appears. FEL returning 0 is *not* evidence that the Linux kernel booted.
5. On success, use a serial terminal to run `uname -a`, `cat /proc/cmdline`, `cat /proc/device-tree/chosen/linux,initrd-start | od -An -tx1`, `dmesg | tail -n 100`, `ls -l /dev/eink-panel`. Do not apply E Ink waveform or VCOM writes until hardware validation.

If USB does not enumerate, boot a minimal diagnostic initramfs with a power LED heartbeat. Keep other experimental kernel and DTB parameters fixed to isolate the failure.

## Open issues
- `direct-entry.bin` needs a source audit to establish whether it already adds DTB initrd properties or incorrectly passes arguments.
- ELAN KTF2K is not established compatible with the standard `elan,ekth3500` binding.
- E Ink needs a verified userspace waveform refresh engine; a loaded `sun5ieink` module does not prove a working screen.
- Frontlight PWM/backlight remains untested on this specific board.
- microSD I/O stability, Wi-Fi resume, charging, keys and suspend all require actual on-device evidence.
- Do not enable the factory eMMC in diagnostic DTBs or write the internal bootloader.

This is a test-only fix, not a claim of full hardware support.
