#!/usr/bin/env python3
"""Experimental retained-DRAM SPL path for the pinned Megi U-Boot tree.

References: the matching Megi Linux pm-sun5i.c/sleep-sun5i.S RTC ABI and
Allwinner boot0 super-standby sequence. Never use this to patch the existing
hash-qualified binary. Only a separately compiled candidate is produced.
"""
from pathlib import Path
import sys

p = Path(sys.argv[1]) / "arch/arm/mach-sunxi/dram_sun4i.c"
s = p.read_text()

if "#include <pb626-led.h>" not in s:
    if s.count("#include <common.h>") != 1:
        raise SystemExit("Unknown DRAM include context")
    s = s.replace("#include <common.h>", "#include <common.h>\n#include <pb626-led.h>")

def change(old, new):
    global s
    if s.count(old) != 1:
        raise SystemExit("Unknown DRAM source context: " + old[:70])
    s = s.replace(old, new)

change("static unsigned long dramc_init_helper(struct dram_para *para)",
       "static unsigned long dramc_init_helper(struct dram_para *para,\n"
       "\t\t\t\t       bool retained, u32 saved_dcr, u32 saved_zq)")
change("\t/* setup DRAM relative clock */\n\tmctl_setup_dram_clock(para->clock, para->mbus_clock);\n\n"
       "\t/* Disable any pad power save control */\n\tmctl_disable_power_save();",
       "\t/* Resume has already enabled controller access while pads are held. */\n"
       "\tif (!retained) {\n\t\tmctl_setup_dram_clock(para->clock, para->mbus_clock);\n"
       "\t\tmctl_disable_power_save();\n\t}")
change("\treg_val |= DRAM_DCR_MODE(DRAM_DCR_MODE_INTERLEAVE);\n\twritel(reg_val, &dram->dcr);",
       "\treg_val |= DRAM_DCR_MODE(DRAM_DCR_MODE_INTERLEAVE);\n"
       "\tif (retained && saved_dcr != reg_val)\n\t\treturn 0;\n"
       "\twritel(reg_val, &dram->dcr);")
change("\tmctl_set_impedance(para->zq, para->odt_en);\n\n\tmctl_set_cke_delay();\n\n\tmctl_ddr3_reset();",
       "\tif (!retained)\n\t\tmctl_set_impedance(para->zq, para->odt_en);\n\n"
       "\tmctl_set_cke_delay();\n\n"
       "\t/* Do not assert DDR3 RESET on a retained image. */\n"
       "\tif (retained)\n\t\tsetbits_le32(&dram->mcr, DRAM_MCR_RESET);\n"
       "\telse\n\t\tmctl_ddr3_reset();")
change("\t/* initialize external DRAM */\n\tmctl_ddr3_initialize();\n\n\t/* scan read pipe value */",
       "\t/* Initialize the controller while external pads are still held. */\n"
       "\tmctl_ddr3_initialize();\n\n"
       "\tif (retained) {\n"
       "\t\t/* Vendor super-standby sequence: restore impedance, set\n"
       "\t\t * controller self-refresh before releasing pad hold, exit,\n"
       "\t\t * then issue refresh. Linux saved the DQS training area. */\n"
       "\t\twritel(0x17b00000 | (saved_zq & 0xfffff), &dram->zqcr0);\n"
       "\t\tclrsetbits_le32(&dram->dcr, 0x1fU << 27, 0x12U << 27);\n"
       "\t\tawait_bits_clear(&dram->dcr, 1U << 31);\n\t\tudelay(20);\n"
       "\t\tmctl_disable_power_save();\n"
       "\t\tawait_bits_clear(&dram->ppwrsctl, 1);\n"
       "\t\tclrsetbits_le32(&dram->dcr, 0x1fU << 27, 0x17U << 27);\n"
       "\t\tawait_bits_clear(&dram->dcr, 1U << 31);\n\t\tudelay(20);\n"
       "\t\tclrsetbits_le32(&dram->dcr, 0x1fU << 27, 0x13U << 27);\n"
       "\t\tawait_bits_clear(&dram->dcr, 1U << 31);\n\t\tudelay(20);\n\t}\n\n"
       "\t/* scan read pipe value */")
change("\treturn get_ram_size((long *)PHYS_SDRAM_0, PHYS_SDRAM_0_SIZE);",
       "\t/* get_ram_size probes and writes arbitrary RAM: forbidden on resume. */\n"
       "\tif (retained)\n\t\treturn 256UL << 20;\n"
       "\treturn get_ram_size((long *)PHYS_SDRAM_0, PHYS_SDRAM_0_SIZE);")
change("unsigned long dramc_init(struct dram_para *para)\n{", r'''
/* PB626/Megi Linux RTC ABI. These registers survive the PMIC power cut.
 * This candidate is only for the 256 MiB A13 board and matching kernel.
 * Menu/FEL runs in the earlier assembly hook; FEL uploads never resume. */
#define PB626_RTC_GP(n) ((void *)(0x01c20d20U + 4U * (n)))
#define PB626_WDOG_CTL ((void *)0x01c20c90U)
#define PB626_WDOG_MODE ((void *)0x01c20c94U)
#define PB626_SUSP_MAGIC 0x53555350U

static void pb626_resume_watchdog(void)
{
	/* sunxi_wdt: interval 8 = 10 s; enable reset and watchdog. */
	writel((8U << 3) | 3U, PB626_WDOG_MODE);
	writel((0x0a57U << 1) | 1U, PB626_WDOG_CTL);
}

static void __attribute__((noreturn)) pb626_resume_failed(unsigned int code)
{
	/* Show the reason once, then the already-armed watchdog cold-resets. */
	pb626_led_error(code);
}

static void pb626_try_resume(struct dram_para *para)
{
	struct sunxi_dram_reg *dram = (void *)SUNXI_DRAMC_BASE;
	u32 addr, dcr, zq, density, io, bus, sctlr;

	if (readl(PB626_RTC_GP(2)) != PB626_SUSP_MAGIC)
		return;
	addr = readl(PB626_RTC_GP(1));
	zq = readl(PB626_RTC_GP(0));
	dcr = readl(PB626_RTC_GP(3)) & ~(0x1fU << 27);

	/* Consume before any destructive fallback or watchdog retry. */
	writel(0, PB626_RTC_GP(2));
	asm volatile("dsb sy" ::: "memory");

	/* eGON.FEL is an explicit RAM rescue upload. Never jump into a
	 * retained OS image during FEL. The earlier Menu hook has priority. */
	if (readl((void *)4) != 0x4e4f4765U ||
	    readl((void *)8) != 0x3054422eU)
		return;
	if (addr < 0x40008000U || addr >= 0x50000000U || (addr & 3))
		return;
	if (!(dcr & 1) || ((dcr >> 10) & 3))
		return;
	/* The pinned helper encodes para->io_width >> 3 directly. */
	io = ((dcr >> 1) & 3) * 8U;
	if (io != 8 && io != 16)
		return;
	density = (dcr >> 3) & 7;
	if (density > 5)
		return;
	density = 256U << density;
	bus = 8U * (1U + ((dcr >> 6) & 7));
	if ((bus != 16 && bus != 32) || bus < io ||
	    density * (bus / io) / 8 != 256)
		return;
	/* Validate the geometry before touching the DRAM clock/pads. */
	if (dcr != (DRAM_DCR_TYPE_DDR3 |
		    DRAM_DCR_IO_WIDTH(io >> 3) |
		    DRAM_DCR_CHIP_DENSITY((readl(PB626_RTC_GP(3)) >> 3) & 7) |
		    DRAM_DCR_BUS_WIDTH((bus >> 3) - 1) |
		    DRAM_DCR_CMD_RANK_ALL |
		    DRAM_DCR_MODE(DRAM_DCR_MODE_INTERLEAVE)))
		return;

	/* Arm before clock setup: retained-state recovery must never hang
	 * without the cold-reset escape. Linux stops it on successful resume. */
	pb626_resume_watchdog();
	mctl_setup_dram_clock(para->clock, para->mbus_clock);
	if (!(readl(&dram->ppwrsctl) & 1)) {
		writel(0, PB626_WDOG_MODE);
		return;
	}

	/* No relocation or RAM size probing after this point. */
	para->io_width = io;
	para->bus_width = bus;
	para->density = density;
	if (dramc_init_helper(para, true, dcr, zq) != (256UL << 20))
		pb626_resume_failed(PB626_ERR_RESUME_DRAM);

	asm volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr));
	if (sctlr & 5)
		pb626_resume_failed(PB626_ERR_RESUME_CPU_STATE);
	sctlr &= ~0x1800U;
	asm volatile("cpsid if\n"
		     "mcr p15, 0, %0, c1, c0, 0\n"
		     "mov r0, #0\n"
		     "mcr p15, 0, r0, c7, c5, 0\n"
		     "mcr p15, 0, r0, c7, c5, 6\n"
		     "dsb sy\nisb sy\n"
		     "bx %1\n"
		     : : "r"(sctlr), "r"(addr) : "r0", "memory");
	pb626_resume_failed(PB626_ERR_RESUME_CPU_STATE);
}

unsigned long dramc_init(struct dram_para *para)
{''')
change("\tif (!para)\n\t\treturn 0;\n\n\t/* if everything is known", 
       "\tif (!para)\n\t\treturn 0;\n\n\tpb626_try_resume(para);\n\n\t/* if everything is known")
s = s.replace("dramc_init_helper(para)", "dramc_init_helper(para, false, 0, 0)")
p.write_text(s)
