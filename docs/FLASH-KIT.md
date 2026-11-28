# PB626 firmware and recovery artifacts

The [Windows installer](WINDOWS-FLASH.md) is the normal supported installation
path. It contains Debian 13 armhf, the paired Linux kernel, DTB, modules,
resume bootloader, RAM recovery and host tools. The former standalone Linux
flash kit used the historical cold-boot SPL and is no longer produced;
the Linux recovery artifact remains available. Historical Linux/WSL and
Alpine installation procedures are retained in the repository for reference.

## Build graph

One Linux kernel is compiled and checked, including SUN5I_PM and the
actual SRAM object. Debian rootfs and independent RAM recovery use that
same kernel. The bootloader build compares the cold and resume paths
with the historical reference before the installer is assembled. The
installer checks all manifests and exact same-run authorization.

| Artifact | Content |
| --- | --- |
| pb626-windows-installer | Complete paired installer and RAM recovery |
| pb626-native-debian13-armhf | Debian rootfs, raw kernel/DTB, module ABI, package list |
| pb626-kernel-stage | Kernel, modules, DTBs, UAPI, config, SRAM object |
| pb626-debian-recovery | RAM-only Debian BusyBox recovery and host restore tools |
| pb626-bootloader-stage | Source-built bootloader files and model inputs |
| pb626-spl-emulation-report | Mandatory differential model results |
| pb626-diagnostics | Standalone diagnostics |
| pb626-full-build-report | Exact checkout and required job results |

Stage artifacts are build inputs, not independently installable firmware.
Use the complete installer instead of mixing stages from different runs.

## Build caching

The immutable pinned Linux Git objects have a separate cache. A kernel
patch change invalidates compiled content but does not require downloading
the same source history again when this cache is present. The E Ink
renderer CI fetches only the exact source blobs touched by patches and
the UAPI header. Compiler/toolchain, resolved config, patch and board
inputs remain part of compiled-kernel cache keys.

Debian minbase, native binaries, rootfs, recovery payload and host tools
retain their separate input-keyed caches. BUILD-COMMIT identifies the
current verified assembly; CONTENT-BUILD-COMMIT records cached native
content provenance. The final gate requires all selected jobs to pass.
CI does not establish physical wake or retention.

## Flash and restore semantics

Install writes the p1 filesystem, its raw kernel/DTB from LBA 80 and
the primary BT0 at LBA 16–63 last. It does not change the MBR/EBR,
BT1, other factory partitions or hardware boot areas. The same-run
RAM recovery authorizes exactly the bootloader hash bound to its
manifest. No arbitrary hash can be supplied by a peer.

Restore writes changed blocks from a verified full dump, including
user, boot0 and boot1. EXT_CSD is recorded and checked, not blindly
programmed. RPMB is not a raw restorable region. A backup is not a
substitute for a working physical recovery route.

See [Windows flashing](WINDOWS-FLASH.md) for preparation, verification,
backup and reconnect instructions, and [suspend](SUSPEND.md) for hardware
acceptance.
