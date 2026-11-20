# Bootstrap ARMv7 userland

An isolated ARMv7 userland is the first build target. This artifact is **not**
a firmware image, a kernel or an E Ink desktop.

The `ARMv7 userland` workflow downloads Alpine Linux 3.24.4 minirootfs for
ARMv7 over HTTPS, checks the upstream SHA256 file, and runs its BusyBox
binary under QEMU user mode on GitHub Actions. It produces a rootfs tarball,
SHA256SUMS and a warning marker.

**Compatibility gate:** successful execution on the Actions runner does not
prove that Alpine musl and its packages work with the stock PocketBook Linux
3.0.8 kernel. The replacement kernel, mount layout, writable storage and
available privileges have not been validated. Do not extract the tarball over
the vendor root filesystem or flash it to the eMMC.

A temporary root filesystem may eventually be tested from user storage or a
filesystem image with suitable mounts. This requires independently verified
root access and a stock-kernel runtime test first.

## Hardware milestones

1. Get temporary privileged execution without a firmware downgrade.
2. Capture a private, verified full eMMC backup, including both hardware boot
   areas and the boot configuration; do not publish the image.
3. Test the isolated ARMv7 userspace without modifying vendor mount points.
4. Assemble and boot a board-specific modern kernel non-destructively, after
   recovery can be demonstrated on this device.
5. Implement the verified ELAN input path, Wi-Fi, E Ink waveform bridge and a
   touch-oriented graphical shell.

The planned modern Linux system must not silently degrade to an unsupported
stock-kernel chroot; the initial userland is a test component and not the
finished product.
