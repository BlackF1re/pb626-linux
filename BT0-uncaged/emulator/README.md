# PB626 Cortex-A8 differential validation

The actual private, hardware-tested 24 KiB BT0 is the reference, not a
reconstructed approximation. Configure the Actions repository secret
PB626_REFERENCE_SPL_B64 from the verified binary (base64 without line
breaks, 32768 bytes). The SHA256 is enforced; the secret is not published
in artifacts or logs. Do not publish the historical SPL until its
corresponding source/license status is resolved.

    base64 -w0 BT0-uncaged.bin | gh secret set PB626_REFERENCE_SPL_B64 --repo BlackF1re/pb626-linux

For local use, with Python 3 and the pinned dependencies:

    python -m pip install -r BT0-uncaged/emulator/requirements.txt
    python BT0-uncaged/emulator/validate.py --reference BT0-uncaged.bin --candidates source-boot-candidates --report emulation.json --require-reference

The same Unicorn Cortex-A8 engine executes machine code from each
eGON image, starting at address zero for the Menu hook. SRAM, LRADC,
GPIO PE8, clock gate, RTC magic and timer register are explicit models.
The normal path and deep candidate cold path must match the reference
Menu/FEL decisions and preserved registers. The raw-sector function is
executed, with the configured user-area offset accounted for separately.
The startup LED functions execute actual ARM instructions with exact
virtual timer counts, including wraparound and FEL/retained-state skip.

A full-boot probe deliberately stops at the first unmodelled access.
It does NOT return arbitrary success values for clock, DRAM, PMIC or MMC
registers. These controllers and the eMMC image/boot protocol still need
models before a full end-to-end boot can be a mandatory test. No optical,
electrical or retained-memory hardware qualification is implied.
The candidate artifact is uploaded before emulation, so the report can
diagnose failures. Missing reference fails differential validation
after candidate-only checks; no false green reference result.

Startup is cooperative: existing timer reads service the 30/50/30/30 ms
thresholds, with no artificial wait. If a long operation does not read
the timer, an edge can be late or skipped. Exact independent hardware
timing would require a qualified interrupt-driven implementation.
