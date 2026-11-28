# Source reconstruction

The historical U-Boot workflow at 4c985f71d4eb333feed023f9bb0d72e5b2dec58e
pins https://codeberg.org/megi/u-boot.git at
96c08df75f632622c57954940d6a1a6c20062e18, with
pocketbook_touch_lux_3_defconfig. This is a concrete source/config
reference from this project, not a generic A13 tablet configuration.
It built a standalone U-Boot experiment; it is NOT evidence of exact
identity with the privately built 24 KiB lab SPL.

The stock archive README explicitly says allocated files only, not raw
partition images. Its boot.axf and script.bin are not the primary BT0.
The separate first-68-MiB raw dump supplied later contains genuine factory
BT0/BT1; see [factory suspend evidence](../docs/FACTORY-SUSPEND.md).
This vendor bootloader is not the historical lab U-Boot SPL.
The new source build uses the historical Megi board defconfig, recreates
the FEL entry contract in assembly, builds patched sunxi-tools, and
links the Menu algorithm against save_boot_params rather than assuming
the old address 0xd70. The native configuration requests raw legacy
uImage at sector 80. It must be reviewed against the actual source and
validated on hardware. The workflow builds both a cold-path comparison image and the resume SPL;
the Windows installer includes the matched resume SPL after model checks.

The source build uses public inputs; the mandatory differential model
still needs the private historical reference. The normal kernel enables
SUN5I_PM and the installer verifies the exact paired SPL. Old fixed-address
binary tests do not certify a newly linked SPL; verify hardware wake and
cold recovery before enabling unattended suspend.

## Recovered original lab build (archive inspection)

The original full U-Boot binary is 284992 bytes; its first 24576 bytes
are the exact lab SPL. The embedded banner identifies
U-Boot 2020.07-00059-g38fcae2e23e2-dirty, built 2023-07-17 with
arm-linux-musleabihf-gcc 13.1.1 20230716 and GNU ld 2.40.0.20230703.
The original distribution is https://xff.cz/kernels/bootloaders/pb/;
its README identifies the same revision. The local combined binary SHA256
is ad00580889a797836b05ed8c718c11d5ccb014aa266707c4f41fa89d192fb87f.
The upstream download must match this hash before extracting the lab SPL.
The exact dirty source tree is still unrecovered; the newer 2021.04
candidate must not be represented as a reproduction.

The original direct-entry.S is recovered and rebuilt to the exact 52-byte
SHA256 1a0044b4533ce91bb1f19f5fef9f1356242d3855cadd4087cc1c6a6ac22a21dd.
The lab sunxi-tools source includes not only the MMU override, but the
8 KiB maximum USB send chunks and legacy U-Boot DRAM read probes.
The recovered patch is checked against the original fel.c and fel_lib.c
hashes. A locally rebuilt host tool ran --help and --list-socs; USB
qualification remains pending. See build-fel-host.sh and FLASH-KIT.md.

The recovered lab dram_sun4i.c and pb626-defconfig are byte-identical to
those copied from the currently pinned 2021.04 tree by Actions:
SHA256 f21f7d1e7a3f1eeb93ba534481f38be934e9afdae3c661e9ec855ec2acf8ba22
and 6f3ff47100a5bb84e03088a327a4ef83ba8e51e88f3f302da7d4d1766d5d5ae7.
This is useful source-level evidence, not proof of identical compiled SPL.
