#if defined(_WIN32)

#include <stddef.h>
#include <sys/stat.h>
#include <uv.h>
#include <windows.h>
#include <string.h>

#undef _environ
#undef environ

extern "C" {
char** environ = nullptr;
char** _environ = nullptr;

int strncasecmp(const char* left, const char* right, size_t length)
{
    return _strnicmp(left, right, length);
}

int fstat64(int fd, struct _stat64* result)
{
    return _fstat64(fd, result);
}

int stat64(const char* path, struct _stat64* result)
{
    return _stat64(path, result);
}

int kill(int pid, int signal)
{
    return uv_kill(pid, signal);
}
}

#endif
