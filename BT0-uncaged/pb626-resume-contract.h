/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PB626_RESUME_CONTRACT_H
#define PB626_RESUME_CONTRACT_H

/* Factory BT0 contains one 2048 Mbit x16 DDR3 device on a 16-bit bus,
 * not the 512 MiB x8 geometry in script.bin. DCR bits 0..11 encode
 * type, I/O width, density, bus and rank. The source-specific high
 * bits are checked separately by the SPL. */
#define PB626_DRAM_IO_WIDTH 16U
#define PB626_DRAM_BUS_WIDTH 16U
#define PB626_DRAM_DENSITY 2048U
#define PB626_DRAM_BYTES (256UL << 20)
#define PB626_DRAM_GEOMETRY 0x05dU
#define PB626_DRAM_GEOMETRY_MASK 0xfffU

static inline int pb626_resume_metadata_valid(unsigned int addr,
                                              unsigned int dcr,
                                              unsigned int zq)
{
    return addr >= 0x40008000U && addr < 0x50000000U &&
           !(addr & 3U) && (dcr & PB626_DRAM_GEOMETRY_MASK) == PB626_DRAM_GEOMETRY &&
           zq <= 0xfffffU;
}
#endif
