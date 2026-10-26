#if defined(__APPLE__)

#include "BunPanic.h"
#include <__verbose_abort>
#include <algorithm>
#include <cstdarg>
#include <cstdio>

void std::__libcpp_verbose_abort(char const* format, ...) noexcept
{
    va_list arguments;
    va_start(arguments, format);
    char buffer[1024];
    int written = vsnprintf(buffer, sizeof(buffer), format, arguments);
    va_end(arguments);

    if (written < 0)
        BUN_PANIC("Failed to format libc++ abort message");
    bunPanic(buffer, std::min(static_cast<size_t>(written), sizeof(buffer) - 1));
}

#endif
