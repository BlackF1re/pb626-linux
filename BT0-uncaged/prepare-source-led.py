#!/usr/bin/env python3
"""Integrate the PB626 PE8 startup and fatal Morse indication into SPL source."""
from pathlib import Path
import sys

repo = Path(__file__).resolve().parent
tree = Path(sys.argv[1])

def copy_once(source, destination):
    data = source.read_text()
    if destination.exists() and destination.read_text() != data:
        raise SystemExit("Refusing to overwrite different source: " + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(data)

def change(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit("Unknown or ambiguous source context in " + str(path) + ": " + old[:90])
    path.write_text(text.replace(old, new))

# Keep the timing model shared with the host unit test.
copy_once(repo / "led-morse.h", tree / "include/pb626-led-morse.h")
copy_once(repo / "pb626-led.h", tree / "include/pb626-led.h")
copy_once(repo / "pb626-led.c", tree / "arch/arm/mach-sunxi/pb626-led.c")

makefile = tree / "arch/arm/mach-sunxi/Makefile"
make_text = makefile.read_text()
entry = "obj-$(CONFIG_SPL_BUILD) += pb626-led.o\n"
if entry not in make_text:
    makefile.write_text(make_text.rstrip() + "\n" + entry)

# SPL image loading: preserve distinct failure codes at the point where the
# failure is still known, rather than collapsing every error into hang().
spl = tree / "common/spl/spl.c"
change(spl, "#include <spl.h>", "#include <spl.h>\n#include <pb626-led.h>")
change(spl,
       'puts("SPL: Image data CRC check failed!\\n");\n\t\t\tret = -EINVAL;',
       'puts("SPL: Image data CRC check failed!\\n");\n'
       '\t\t\tpb626_led_error(PB626_ERR_PAYLOAD_CRC);\n'
       '\t\t\tret = -EINVAL;')
change(spl,
       'puts(SPL_TPL_PROMPT "failed to boot from all boot devices\\n");\n\t\t hang();',
       'puts(SPL_TPL_PROMPT "failed to boot from all boot devices\\n");\n'
       '\t\t pb626_led_error(PB626_ERR_MMC_FIND);')

mmc = tree / "common/spl/spl_mmc.c"
change(mmc, "#include <image.h>", "#include <image.h>\n#include <pb626-led.h>")
change(mmc,
       '\tret = spl_parse_image_header(spl_image, header);\n\tif (ret)\n\t\treturn ret;',
       '\tret = spl_parse_image_header(spl_image, header);\n'
       '\tif (ret)\n'
       '\t\tpb626_led_error(PB626_ERR_HEADER_CRC);')
change(mmc,
       '\tif (count != image_size_sectors)\n\t\treturn -EIO;',
       '\tif (count != image_size_sectors)\n'
       '\t\tpb626_led_error(PB626_ERR_PAYLOAD_READ);')
change(mmc,
       '\tif (count == 0) {\n\t\tret = -EIO;\n\t\tgoto end;\n\t}',
       '\tif (count == 0) {\n'
       '\t\tpb626_led_error(PB626_ERR_HEADER_READ);\n'
       '\t\tret = -EIO;\n'
       '\t\tgoto end;\n'
       '\t}')
change(mmc,
       '\tmmc_dev = spl_mmc_get_device_index(boot_device);\n'
       '\tif (mmc_dev < 0)\n\t\treturn mmc_dev;',
       '\tmmc_dev = spl_mmc_get_device_index(boot_device);\n'
       '\tif (mmc_dev < 0)\n'
       '\t\tpb626_led_error(PB626_ERR_MMC_FIND);')
change(mmc,
       '\t\treturn err;\n\t}\n\t*mmcp = find_mmc_device(mmc_dev);',
       '\t\tpb626_led_error(PB626_ERR_MMC_INIT);\n'
       '\t}\n\t*mmcp = find_mmc_device(mmc_dev);')
change(mmc,
       '\t\treturn err;\n\t}\n\n\treturn 0;\n}',
       '\t\tpb626_led_error(PB626_ERR_MMC_FIND);\n'
       '\t}\n\n\treturn 0;\n}')

# DRAM timeouts and failed initialization have separate, actionable codes.
dram_helpers = tree / "arch/arm/mach-sunxi/dram_helpers.c"
change(dram_helpers, "#include <common.h>",
       "#include <common.h>\n#include <pb626-led.h>")
change(dram_helpers,
       '\t\tif (timer_get_us() > tmo)\n'
       '\t\t\tpanic("Timeout initialising DRAM\\n");',
       '\t\tif (timer_get_us() > tmo) {\n'
       '#ifdef CONFIG_SPL_BUILD\n'
       '\t\t\tpb626_led_error(PB626_ERR_DRAM_TIMEOUT);\n'
       '#else\n'
       '\t\t\tpanic("Timeout initialising DRAM\\n");\n'
       '#endif\n'
       '\t\t}')

board = tree / "board/sunxi/board.c"
change(board, "#include <spl.h>", "#include <spl.h>\n#include <pb626-led.h>")
change(board,
       '\tif (!gd->ram_size)\n\t\thang();',
       '\tif (!gd->ram_size)\n'
       '\t\tpb626_led_error(PB626_ERR_DRAM_INIT);')

print("Integrated PB626 PE8 solid-start indication and SPL Morse failure paths")
