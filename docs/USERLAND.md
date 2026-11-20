# Bootstrap ARMv7 userland

An isolated ARMv7 userland is the first build target. This artifact is **not**
a firmware image, a kernel or an E Ink desktop.

The `ARMv7 userland` workflow downloads Alpine Linux 3.24.4 minirootfs for
ARMv7 over HTTPS, checks the upstream SHA256 file, and runs its BusyBox
binary under QEMU user mode on GitHub Actions. It produces a rootfs tarball,
SHA256SUMS and a warning marker.

**Compatibility gate:** successful execution on the Actions runner does not
prove this specific artifact is bootable on the reader. Separately, an earlier
locally prepared Alpine rootfs **did boot from external microSD** using a
RAM-loaded FEL kernel, with SSH and package installation demonstrated.
Those local sources and kernel have not been imported into this repository.
Never extract this tarball over the vendor root filesystem or flash eMMC.

The existing external-microSD rootfs has an unresolved ext4 journal issue.
Prioritize recovery and preservation of the working lab assets, then move
the source build into Actions. See [FEL lab status](FEL-LAB-STATUS.md).

## Hardware milestones

1. Preserve the previous local FEL build tree and recover the microSD ext4
   filesystem without touching eMMC.
2. Reproduce the working headless FEL kernel and Alpine rootfs in Actions.
3. Validate E Ink update, waveforms and frontlight; establish touchscreen
   controller support and map input events.
4. Implement an E Ink-first general-purpose shell and verify suspend/resume.
5. Keep a verified rollback route before considering any permanent eMMC
   installation. A private full backup would be required for that later step.

The planned modern Linux system must not silently degrade to an unsupported
stock-kernel chroot; the initial userland is a test component and not the
finished product.
