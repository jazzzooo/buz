#include "BunStdio.h"

void bun_stdio_disable_buffering(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}
