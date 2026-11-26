#ifndef PB626_TEST_DELAY_H
#define PB626_TEST_DELAY_H
void pb626_test_udelay(unsigned long usec);
#define udelay(usec) pb626_test_udelay(usec)
#endif
