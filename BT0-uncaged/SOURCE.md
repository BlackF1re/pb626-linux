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
The new source build uses the historical Megi board defconfig, recreates
the FEL entry contract in assembly, builds patched sunxi-tools, and
links the Menu algorithm against save_boot_params rather than assuming
the old address 0xd70. The native configuration requests raw legacy
uImage at sector 80. It must be reviewed against the actual source and
validated on hardware. The workflow emits a separate candidate artifact,
never the qualified install image.

No old private input is needed to attempt this source build. Preserve
the exact existing installer gates and the working SPL. The Codeberg
tree was not accessible from the chat environment; CI is the first
compilation check. The audit output records any existing DRAM resume
implementation; if absent, the missing retention path must be ported
and tested separately before CONFIG_SUN5I_PM can be enabled. The
old fixed-address binary hook tests do not certify a newly linked SPL.
