#pragma once

#include <stdio.h>
#include <stdlib.h>
#include "BunCloseRange.h"
#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

void bun_stdio_disable_buffering(void);

#ifdef __cplusplus
}
#endif
