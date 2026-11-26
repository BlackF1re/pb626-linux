#!/usr/bin/env python3
"""Link the existing Menu algorithm by symbols rather than old SPL offsets."""
from pathlib import Path
import re
import sys

tree = Path(sys.argv[1])
hook = Path(__file__).with_name("early-menu.S").read_text()
hook = hook.replace(".global _start", ".global pb626_menu_hook").replace("_start:", "pb626_menu_hook:")
hook = hook.replace("movweq r3,#0x0d70", "ldreq r3,=save_boot_params")
# PE8 is active low. Hold it on throughout the native boot path without
# adding a delay; Linux gpio-leds and init-megi take over at kernel startup.
# Menu/FEL and ambiguous-key recovery turn it back off before returning.
hook = hook.replace(
    "cpsid if",
    """cpsid if
    ldr r0,=0x01c208a0
    ldr r1,[r0]
    bic r1,r1,#0x100
    str r1,[r0]
    ldr r0,=0x01c20894
    ldr r1,[r0]
    bic r1,r1,#0xf
    orr r1,r1,#1
    str r1,[r0]
    dsb sy""",
    1,
)
hook = hook.replace(
    "finish:",
    """    cmp r7,#1
    beq 99f
    ldr r0,=0x01c208a0
    ldr r1,[r0]
    orr r1,r1,#0x100
    str r1,[r0]
    dsb sy
99:
pb626_finish:""",
    1,
)
if "99:" not in hook:
    raise SystemExit("PB626 LED recovery-off sequence was not inserted")
hook = hook.replace(".org 0x400", ".balign 4")
for label in ("report", "sample", "poll", "have_sample", "next_sample", "restore", "rom_entry", "finish"):
    hook = re.sub(r"\b" + label + r"\b", "pb626_" + label, hook)
# Include only in the SPL assembler translation unit. The section is
# normal linked text; the report is no longer at a historical absolute address.
p = tree / "arch/arm/cpu/armv7/start.S"
s = p.read_text()
match = re.search(r"(?m)^([ \t]*b[ \t]+save_boot_params[ \t]*)$", s)
if not match:
    raise SystemExit("Unknown source entry, inspect manually")
s = s[:match.start()] + """#if defined(CONFIG_SPL_BUILD) || defined(CONFIG_XPL_BUILD)
    b pb626_menu_hook
#else
""" + match.group(1) + """
#endif""" + s[match.end():]
s += "\n#if defined(CONFIG_SPL_BUILD) || defined(CONFIG_XPL_BUILD)\n" + hook + "\n#endif\n"
p.write_text(s)
