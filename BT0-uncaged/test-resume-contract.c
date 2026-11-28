/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <stdio.h>
#include "pb626-resume-contract.h"

int main(void)
{
    assert(PB626_DRAM_DENSITY * (PB626_DRAM_BUS_WIDTH / PB626_DRAM_IO_WIDTH) / 8 ==
           PB626_DRAM_BYTES / (1UL << 20));
    assert(pb626_resume_metadata_valid(0x40008000U, 0x305dU, 0));
    assert(pb626_resume_metadata_valid(0x4ffffffcU, 0x305dU, 0xfffffU));
    assert(!pb626_resume_metadata_valid(0x40007ffcU, 0x305dU, 0));
    assert(!pb626_resume_metadata_valid(0x50000000U, 0x305dU, 0));
    assert(!pb626_resume_metadata_valid(0x40008002U, 0x305dU, 0));
    /* Same capacity but x8 geometry: not the observed board. */
    assert(!pb626_resume_metadata_valid(0x40008000U, 0x3053U, 0));
    /* Factory script.bin describes a 512 MiB x8 configuration. */
    assert(!pb626_resume_metadata_valid(0x40008000U, 0x305bU, 0));
    for (unsigned int bit = 0; bit < 12; bit++)
        assert(!pb626_resume_metadata_valid(0x40008000U, 0x305dU ^ (1U << bit), 0));
    assert(!pb626_resume_metadata_valid(0x40008000U, 0x305dU, 0x100000U));
    puts("Observed PB626 retained-DRAM metadata geometry checks passed");
    return 0;
}
