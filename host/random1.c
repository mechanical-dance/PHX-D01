/* LXR02Open's random.c drives the STM32 RNG registers directly; natively, use the system RNG. */
#include <stdint.h>
#include <stdlib.h>
void initRng(void) {}
int16_t GetRngValue(void) { return (int16_t)arc4random(); }
