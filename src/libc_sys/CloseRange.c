#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "BunCloseRange.h"

#if defined(__linux__) || defined(__FreeBSD__) || defined(__APPLE__)
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <unistd.h>

static int updateDescriptor(int fd, bool cloexec)
{
    if (!cloexec) {
        close(fd);
        return 0;
    }
    int flags;
    do {
        flags = fcntl(fd, F_GETFD);
    } while (flags < 0 && errno == EINTR);
    if (flags < 0) return errno == EBADF ? 0 : -1;
    int result;
    do {
        result = fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
    } while (result < 0 && errno == EINTR);
    return result < 0 && errno != EBADF ? -1 : 0;
}

#if defined(__linux__)
#include <dirent.h>
#include <stddef.h>
#include <string.h>
#include <sys/syscall.h>

static bool descriptorNumber(const unsigned char* name, size_t capacity, uint32_t* out)
{
    uint32_t value = 0;
    for (size_t i = 0; i < capacity; i++) {
        const unsigned char character = name[i];
        if (!character) {
            if (!i) return false;
            *out = value;
            return true;
        }
        if (character < '0' || character > '9' || value > (INT_MAX - (character - '0')) / 10U)
            return false;
        value = value * 10 + (character - '0');
    }
    return false;
}

static int enumerateDescriptors(uint32_t first, uint32_t last, bool cloexec)
{
    int directory;
    do {
        directory = open("/proc/self/fd", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    } while (directory < 0 && errno == EINTR);
    if (directory < 0) return -1;

    // The fork child cannot use allocator-backed directory iteration.
    unsigned char buffer[4096];
    int failure = 0;
    for (;;) {
        long count = syscall(SYS_getdents64, directory, buffer, sizeof(buffer));
        if (count < 0) {
            if (errno == EINTR) continue;
            failure = errno;
            break;
        }
        if (!count) break;
        size_t offset = 0;
        while (offset < (size_t)count) {
            const size_t nameOffset = offsetof(struct dirent64, d_name);
            if ((size_t)count - offset < nameOffset + 1) {
                failure = EIO;
                break;
            }
            unsigned short length;
            memcpy(&length, buffer + offset + offsetof(struct dirent64, d_reclen), sizeof(length));
            if (length <= nameOffset || length > (size_t)count - offset) {
                failure = EIO;
                break;
            }
            uint32_t fd;
            if (descriptorNumber(buffer + offset + nameOffset, length - nameOffset, &fd)
                && fd >= first && fd <= last && fd != (uint32_t)directory) {
                if (updateDescriptor((int)fd, cloexec) < 0 && !failure) failure = errno;
            }
            offset += length;
        }
        if (offset != (size_t)count) break;
    }
    close(directory);
    if (failure) {
        errno = failure;
        return -1;
    }
    return 0;
}
#else
static int enumerateDescriptors(uint32_t first, uint32_t last, bool cloexec)
{
    const int limit = getdtablesize();
    if (limit < 0) return -1;
    int failure = 0;
    for (uint32_t fd = first; fd < (uint32_t)limit && fd <= last; fd++) {
        if (updateDescriptor((int)fd, cloexec) < 0 && !failure) failure = errno;
    }
    if (failure) {
        errno = failure;
        return -1;
    }
    return 0;
}
#endif

int bun_close_range(uint32_t first, uint32_t last, uint32_t flags)
{
    if (first > last || (flags & ~BUN_CLOSE_RANGE_CLOEXEC)) {
        errno = EINVAL;
        return -1;
    }
    if (first > INT_MAX) return 0;
#if defined(__linux__)
    if (syscall(SYS_close_range, first, last, flags) == 0) return 0;
#elif defined(__FreeBSD__)
    if (close_range(first, last, flags) == 0) return 0;
#endif
    return enumerateDescriptors(first, last, flags & BUN_CLOSE_RANGE_CLOEXEC);
}
#endif
