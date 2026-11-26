#ifndef PB626_TEST_MMIO_H
#define PB626_TEST_MMIO_H
#include <stdint.h>
uint32_t pb626_test_readl(uintptr_t address);
void pb626_test_writel(uint32_t value, uintptr_t address);
#endif
