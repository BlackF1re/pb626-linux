// SPDX-License-Identifier: GPL-2.0+
#include <command.h>
#include <cpu_func.h>
#include <linux/libfdt.h>
#include <linux/types.h>

#define PB626_ZIMAGE 0x42000000UL
#define PB626_DTB 0x43200000UL

static int do_pb626_linux(struct cmd_tbl *cmdtp, int flag, int argc,
			 char *const argv[])
{
	void (*kernel_entry)(unsigned int, unsigned int, unsigned int) =
		(void *)PB626_ZIMAGE;

	if (*(const u32 *)(PB626_ZIMAGE + 0x24) != 0x016f2818 ||
	    fdt_check_header((const void *)PB626_DTB))
		return CMD_RET_FAILURE;

	/* The verified DTB already contains /chosen/bootargs and /memory. */
	run_command("i2c mw 0x34 0x0e 0x78 1", 0);
	asm volatile("cpsid if" : : : "memory");
	cleanup_before_linux();
	kernel_entry(0, ~0U, PB626_DTB);

	return CMD_RET_FAILURE;
}

U_BOOT_CMD(pb626_linux, 1, 0, do_pb626_linux,
	   "enter the embedded PocketBook Linux zImage", "");
