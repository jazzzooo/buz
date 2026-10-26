#pragma once

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

int bun_tcc_vprintf(const char* format, va_list arguments);
int bun_tcc_vfprintf(FILE* stream, const char* format, va_list arguments);
int bun_tcc_printf(const char* format, ...);
int bun_tcc_fprintf(FILE* stream, const char* format, ...);

#ifdef __cplusplus
}
#endif
