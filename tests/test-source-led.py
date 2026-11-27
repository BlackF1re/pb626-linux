#!/usr/bin/env python3
"""Exercise strict PB626 SPL LED source integration against U-Boot 2021.04 contexts."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as td:
    tree = Path(td)
    files = {
        "arch/arm/mach-sunxi/Makefile": "obj-y += board.o\n",
        "common/spl/spl.c": r'''#include <spl.h>
void crc(void)
{
		if (dcrc != spl_image->dcrc) {
			puts("SPL: Image data CRC check failed!\n");
			ret = -EINVAL;
		}
}
void load(void)
{
	if (boot_from_devices(spl_boot_list)) {
		puts(SPL_TPL_PROMPT "failed to boot from all boot devices\n");
		hang();
	}
}
''',
        "common/spl/spl_mmc.c": r'''#include <image.h>
static int mmc_load_legacy(struct spl_image_info *spl_image, struct mmc *mmc,
			   ulong sector, struct image_header *header)
{
	ret = spl_parse_image_header(spl_image, header);
	if (ret)
		return ret;
	count = blk_dread(mmc_get_blk_desc(mmc), sector, image_size_sectors,
			  (void *)(ulong)spl_image->load_addr);
	if (count != image_size_sectors)
		return -EIO;
	return 0;
}
static int mmc_load_image_raw_sector(void)
{
	count = blk_dread(bd, sector, 1, header);
	if (count == 0) {
		ret = -EIO;
		goto end;
	}
end:
	return 0;
}
static int spl_mmc_find_device(struct mmc **mmcp, u32 boot_device)
{
	mmc_dev = spl_mmc_get_device_index(boot_device);
	if (mmc_dev < 0)
		return mmc_dev;
	err = mmc_init_device(mmc_dev);
	if (err) {
		printf("spl: could not initialize mmc. error: %d\n", err);
		return err;
	}
	*mmcp = find_mmc_device(mmc_dev);
	err = *mmcp ? 0 : -ENODEV;
	if (err) {
		printf("spl: could not find mmc device %d. error: %d\n",
		       mmc_dev, err);
		return err;
	}

	return 0;
}
''',
        "arch/arm/mach-sunxi/dram_helpers.c": r'''#include <common.h>
void mctl_await_completion(u32 *reg, u32 mask, u32 val)
{
	unsigned long tmo = timer_get_us() + 1000000;
	while ((readl(reg) & mask) != val) {
		if (timer_get_us() > tmo)
			panic("Timeout initialising DRAM\n");
	}
}
''',
        "board/sunxi/board.c": r'''#include <spl.h>
void sunxi_board_init(void)
{
	printf("DRAM:");
	gd->ram_size = sunxi_dram_init();
	printf(" %d MiB\n", (int)(gd->ram_size >> 20));
	if (!gd->ram_size)
		hang();
}
''',
    }
    for name, data in files.items():
        path = tree / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)

    subprocess.run([sys.executable, str(root / "BT0-uncaged/prepare-source-led.py"), str(tree)],
                   check=True)
    assert "pb626-led.o" in (tree / "arch/arm/mach-sunxi/Makefile").read_text()
    assert "PB626_ERR_PAYLOAD_CRC" in (tree / "common/spl/spl.c").read_text()
    assert "PB626_ERR_MMC_FIND" in (tree / "common/spl/spl.c").read_text()
    mmc = (tree / "common/spl/spl_mmc.c").read_text()
    for code in ("MMC_FIND", "MMC_INIT", "HEADER_READ", "HEADER_CRC",
                 "PAYLOAD_READ"):
        assert "PB626_ERR_" + code in mmc
    assert "PB626_ERR_DRAM_TIMEOUT" in (tree / "arch/arm/mach-sunxi/dram_helpers.c").read_text()
    assert "PB626_ERR_DRAM_INIT" in (tree / "board/sunxi/board.c").read_text()
    assert (tree / "arch/arm/mach-sunxi/pb626-led.c").read_bytes() == (
        root / "BT0-uncaged/pb626-led.c").read_bytes()

print("PB626 SPL LED source integration contexts passed")
