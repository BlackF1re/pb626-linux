#ifndef PB626_TEST_IO_H
#define PB626_TEST_IO_H
#include <stdint.h>
#include <pb626-test-mmio.h>
#define readl(addr) pb626_test_readl((uintptr_t)(addr))
#define writel(value, addr) pb626_test_writel((uint32_t)(value), (uintptr_t)(addr))
#endif
