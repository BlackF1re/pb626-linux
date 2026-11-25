# A13 E Ink deferred probe (2026-11-25)

Hardware RAM-only test on late ELAN/eMMC PB626 Plus, pinned Megi commit facc87117511221bb61410e3f92ad8579697f736, built-in E Ink and videobuf2 (Actions run 45645278831).

| Bootargs | video0 registered (seconds since kernel time zero) |
| --- | ---: |
| default | 12.773519 |
| deferred_probe_timeout=1 | 3.429803 |
| fw_devlink=permissive | 1.596563 |

With permissive links, initial regulator acquisition correctly returned -EPROBE_DEFER at 0.102355 s; successful probe preceded PID 1 at 2.039911 s. At 2.07 s during an unmodified-command-line audit boot, debugfs devices_deferred reported:

    1c0c000.display-controller      platform: supplier 1c01000.dram-controller not ready

The MBUS link was dormant; TPS65185 and pinctrl links were available. The MBUS platform device has no bound driver. The DT interconnects/dma-mem pair is required by __of_get_dma_parent() for DMA address translation. CONFIG_SUNXI_MBUS=y provides a bus notifier, not a platform driver for this node; CONFIG_INTERCONNECT is disabled.

The local patch suppresses only automatic firmware device links for the A13 MBUS dma-mem entry when CONFIG_INTERCONNECT is disabled. It keeps the properties, DMA mapping, other links, regulator checks, global timeout and fw_devlink default intact. It does not write hardware registers. The new kernel release suffix prevents mixing modules with previous builds.

Acceptance pending: build, RAM-only FEL boot with empty command line, early video0, successful real waveform scanout, correct regulator behavior; then native eMMC-root boot and matching modules before any persistent kernel update. Do not infer visible output from video0 alone. No BT0 changes.
