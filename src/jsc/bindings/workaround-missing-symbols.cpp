#if defined(WIN32)

#include <cstdint>
#include <algorithm>
#include <sys/stat.h>
#include <uv.h>
#include <fcntl.h>
#include <windows.h>
#include <string.h>
#include <cstdlib>

#undef _environ
#undef environ

// Some libraries need these symbols. Windows makes it
extern "C" char** environ = nullptr;
extern "C" char** _environ = nullptr;

extern "C" int strncasecmp(const char* s1, const char* s2, size_t n)
{
    return _strnicmp(s1, s2, n);
}

extern "C" int fstat64(
    _In_ int _FileHandle,
    _Out_ struct _stat64* _Stat)
{

    return _fstat64(_FileHandle, _Stat);
}

extern "C" int stat64(
    _In_z_ char const* _FileName,
    _Out_ struct _stat64* _Stat)
{
    return _stat64(_FileName, _Stat);
}

extern "C" int kill(int pid, int sig)
{
    return uv_kill(pid, sig);
}

#endif

#if defined(__FreeBSD__) && !ASSERT_ENABLED
// WTF references this counter from text/StringCommon.h under STRING_STATS;
// Debug WebKit defines it (StringView.cpp); Release doesn't, but Bun's
// StringView.h usage still emits a reference.
#include <atomic>
namespace WTF::Detail {
std::atomic<int> wtfStringCopyCount;
}
#endif

// macOS
#if defined(__APPLE__)

#include <version>
#include <dlfcn.h>
#include <cstdint>
#include <cstdarg>
#include <cstdio>
#include "headers.h"

// Check if the stdlib declaration already has noexcept by looking at the header
#ifdef _LIBCPP___VERBOSE_ABORT
#if __has_include(<__verbose_abort>)
#include <__verbose_abort>
#endif
#endif

// Provide our implementation
// LLVM 20 used _LIBCPP_VERBOSE_ABORT_NOEXCEPT, LLVM 21+ uses _NOEXCEPT (always noexcept).
void std::__libcpp_verbose_abort(char const* format, ...) noexcept
{
    va_list list;
    va_start(list, format);
    char buffer[1024];
    size_t len = vsnprintf(buffer, sizeof(buffer), format, list);
    va_end(list);

    Bun__panic(buffer, len);
}

#undef BUN_VERBOSE_ABORT_NOEXCEPT

#endif

extern "C" __attribute__((weak)) void mi_thread_set_in_threadpool() {}
