# Charger-only boot (experimental)

AXP209 datasheet v1.0, section 10.1, register 00H bit 0 reports whether
the PMIC started from ACIN/VBUS. Bits 7 and 5 report live presence, not
startup reason. See https://dl.linux-sunxi.org/AXP/AXP209_Datasheet_v1.0en.pdf
The AXP209 kernel regmap is volatile for this register. The local patch
captures bit 0 before MFD children are probed and exposes read-only
pb626_boot_source and pb626_external_present attributes at the AXP209
I2C device. No charger-current, voltage, IRQ or PMIC settings are changed.
A nonexternal source is not proof of a key press (other resets exist).
The supplied boot.axf contains low-battery/no-external-power shutdown
logic but no base SPL or reproducible bootloader source.

The native default target is pb626-boot.target. The selector starts
multi-user.target normally, including when the PMIC read fails or
qualification is absent. With /etc/pb626/charge-qualified and a reported
external startup, it starts pb626-charge.target only. The normal board,
desktop, gadget and battery-policy services are gated on a per-boot
marker, including udev-activated starts. systemd basic/sysinit services
and the same kernel remain; this is not suspend-to-RAM. No Wi-Fi, Xorg,
Matchbox or browser is started by the charging target. WFI/CPUIdle and
the panel's native Runtime PM remain active.

The compiled helper draws a 758x1024 black/white battery with a large
numeric percentage. It updates only when the integer capacity changes,
using power_supply notifications and a 15-second fallback because the
gauge does not promise an event for every percentage change. Missing
battery telemetry is displayed as --%, not as 100%. The first update
and every tenth changed percentage use the existing full quality mode;
other changes use partial GL16. The same calibrated WBF and scanout
driver are used. On verified absent ACIN and VBUS twice one second apart,
the helper requests normal systemd poweroff. The existing poweroff
screen service runs after the charge helper stops and restores the
configured full-quality PGM (or white). If rendering fails, shutdown
can still proceed; do not delay a critically depleted battery forever.

A new PEK power-button press starts the normal target in the same boot,
without re-reading the startup latch. Failure to open the PEK device,
PMIC or render path returns to normal boot. Normal reboot creates a
one-use persistent normal-next-boot marker, consumed before selection.
Unexpected loss of power during reboot may leave that marker behind;
the safe consequence is one normal boot. pb626.charge=off is a kernel
command-line override. Remove charge-qualified to disable automatic
charger-only boot. No change to BT0, Menu hook, FEL or recovery DTB.

Qualification on the reader is mandatory: record source/presence on
cold button boot, USB/wall-adapter boot, button boot with cable present,
unplug during boot, brownout, reboot while plugged, and Menu+USB FEL.
Verify 0/100/unknown capacity, power button takeover, reconnect/unplug
and the restored shutdown picture, measure current and charging speed.
Confirm whether the PMIC is configured to power on from USB/AC at all.
If the board does not start on input insertion, Linux cannot implement
that behavior while fully off; inspect the PMIC boot configuration
before considering any changes. Never qualify from register docs alone.

## Software acceptance and diagnostic

The host and armhf build run the same pure transition tests: startup
source/override, 0..100 plus unknown gauge, unchanged percentage,
unplug/reconnect within the debounce window, confirmed unplug,
three consecutive failed PMIC reads, and fresh versus repeated PEK
events. The service polls the PEK and power_supply netlink fd, checks
fresh PMIC telemetry and uses a 15-second fallback. Absence needs two
samples separated by at least one second and a final recheck; a
reconnect cancels shutdown. Netlink overflow triggers a new sample.
A failed partial render retries the existing full-quality mode.
No synthetic test calls the real host power manager.

On the running reader, `sudo /usr/libexec/pb626-charge probe` prints
the latched startup source, live external presence, capacity and PEK
availability. Record this before enabling the qualification marker.
The helper does not change the PMIC charger current or disable hardware
drivers. Kernel device discovery can still load the Wi-Fi driver even
though the iwd/desktop user session is not started. Physical standby
current, regulator behavior and boot on cable insertion remain hardware
tests, not consequences of the systemd target graph alone.
