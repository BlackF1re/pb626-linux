#!/usr/bin/env python3
"""Link the existing Menu algorithm by symbols rather than old SPL offsets."""
from pathlib import Path
import re
import sys

tree = Path(sys.argv[1])
hook = Path(__file__).with_name("early-menu.S").read_text()
hook = hook.replace(".global _start", ".global pb626_menu_hook").replace("_start:", "pb626_menu_hook:")
hook = hook.replace("movweq r3,#0x0d70", "ldreq r3,=save_boot_params")
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
