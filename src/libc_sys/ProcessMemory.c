#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "BunProcessMemory.h"
#include <errno.h>
#include <stdint.h>

#if defined(__linux__)
#include <fcntl.h>
#include <unistd.h>

static int parseSize(const char** cursor, const char* end, size_t* result)
{
    const char* start = *cursor;
    size_t value = 0;
    while (*cursor < end && **cursor >= '0' && **cursor <= '9') {
        unsigned digit = (unsigned)(*(*cursor)++ - '0');
        if (value > (SIZE_MAX - digit) / 10)
            return EOVERFLOW;
        value = value * 10 + digit;
    }
    if (*cursor == start)
        return EINVAL;
    *result = value;
    return 0;
}

int bun_process_resident_memory(size_t* bytes)
{
    int fd;
    do {
        fd = open("/proc/self/statm", O_RDONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0)
        return errno;

    char buffer[128];
    size_t length = 0;
    int error = 0;
    while (length < sizeof(buffer)) {
        ssize_t count = read(fd, buffer + length, sizeof(buffer) - length);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            error = errno;
            break;
        }
        if (!count)
            break;
        length += (size_t)count;
    }
    // Linux releases the descriptor even when close reports EINTR.
    close(fd);
    if (error)
        return error;

    const char* cursor = buffer;
    const char* end = buffer + length;
    size_t virtualPages;
    error = parseSize(&cursor, end, &virtualPages);
    if (error)
        return error;
    if (cursor == end || (*cursor != ' ' && *cursor != '\t'))
        return EINVAL;
    while (cursor < end && (*cursor == ' ' || *cursor == '\t'))
        ++cursor;
    size_t residentPages;
    error = parseSize(&cursor, end, &residentPages);
    if (error)
        return error;
    if (cursor == end || (*cursor != ' ' && *cursor != '\t' && *cursor != '\n'))
        return EINVAL;

    long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize <= 0)
        return EINVAL;
    if (residentPages > SIZE_MAX / (size_t)pageSize)
        return EOVERFLOW;
    *bytes = residentPages * (size_t)pageSize;
    return 0;
}
#elif defined(__APPLE__)
#include <mach/mach.h>

int bun_process_resident_memory(size_t* bytes)
{
    task_basic_info_data_t info;
    mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return EIO;
    *bytes = (size_t)info.resident_size;
    return 0;
}
#elif defined(__FreeBSD__)
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <unistd.h>

int bun_process_resident_memory(size_t* bytes)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    size_t length = sizeof(info);
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0)
        return errno;
    long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize <= 0)
        return EINVAL;
    if ((size_t)info.ki_rssize > SIZE_MAX / (size_t)pageSize)
        return EOVERFLOW;
    *bytes = (size_t)info.ki_rssize * (size_t)pageSize;
    return 0;
}
#elif defined(_WIN32)
#include <uv.h>

int bun_process_resident_memory(size_t* bytes)
{
    return uv_resident_set_memory(bytes);
}
#else
#error "Unsupported process memory query platform"
#endif
