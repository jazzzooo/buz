#include "TccStdio.h"

int bun_tcc_vfprintf(FILE* stream, const char* format, va_list arguments)
{
    const int result = vfprintf(stream, format, arguments);
    if (result < 0) return result;
    return fflush(stream) == EOF ? EOF : result;
}

int bun_tcc_vprintf(const char* format, va_list arguments)
{
    return bun_tcc_vfprintf(stdout, format, arguments);
}

int bun_tcc_printf(const char* format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    const int result = bun_tcc_vprintf(format, arguments);
    va_end(arguments);
    return result;
}

int bun_tcc_fprintf(FILE* stream, const char* format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    const int result = bun_tcc_vfprintf(stream, format, arguments);
    va_end(arguments);
    return result;
}
