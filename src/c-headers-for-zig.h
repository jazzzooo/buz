// This file is run through translate-c and exposed to Zig code
// under the namespace bun.c (lowercase c). Prefer adding includes
// to this file instead of manually porting struct definitions
// into Zig code. By using automatic translation, differences
// between platforms and subtle mistakes can be avoided.
//
// One way to locate a definition for a given symbol is to open
// Zig's `lib` directory and run ripgrep on it. For example,
// `sockaddr_dl` is in `libc/include/any-macos-any/net/if_dl.h`
//
// When Zig is translating this file, it will define these macros:
// - WINDOWS
// - DARWIN
// - LINUX
// - FREEBSD
// - POSIX

// For `POSIX_SPAWN_SETSID` and some other non-POSIX extensions in glibc
#if LINUX
#define _GNU_SOURCE
#endif

#if FREEBSD
// <sys/time.h> contains static inline arithmetic helpers that translate-c
// cannot emit as valid Zig. The translated declarations only need its public
// structure layouts, so provide those through their leaf headers and
// keep dependent headers from expanding the inline implementation.
#include <sys/types.h>
#include <sys/_timespec.h>
#include <sys/_timeval.h>
struct itimerval {
  struct timeval it_interval;
  struct timeval it_value;
};
#define _SYS_TIME_H_
#endif

// OnBeforeParseResult, etc...
#include "../packages/bun-native-bundler-plugin-api/bundler_plugin.h"

#if POSIX
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <pwd.h>
#if !DARWIN
#include <spawn.h>
#endif
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#if DARWIN
// Darwin's <spawn.h> includes Mach message types that translate-c cannot
// represent on aarch64. Bun uses std.c for the spawn APIs and only needs these
// flag values from the translated headers.
#define POSIX_SPAWN_SETPGROUP 0x0002
#define POSIX_SPAWN_SETSIGDEF 0x0004
#define POSIX_SPAWN_SETSIGMASK 0x0008
#define POSIX_SPAWN_SETEXEC 0x0040
#define POSIX_SPAWN_SETSID 0x0400
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
#include <copyfile.h>
#include <net/if_dl.h>
#include <sys/clonefile.h>
#include <sys/mount.h>
#include <sys/proc_info.h>
#include <sys/stdio.h>
#include <sys/sysctl.h>

int proc_listchildpids(pid_t ppid, void *buffer, int buffersize);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
#elif LINUX
#include <linux/fs.h>
#include <sys/statfs.h>
#include <sys/sysinfo.h>
#elif FREEBSD
#include <arpa/inet.h>
#include <dirent.h>
#include <net/if_dl.h>
#include <sys/event.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/umtx.h>
#include <sys/user.h>
#include <sys/utsname.h>
#endif

#if WINDOWS
#include <windows.h>
#include <winternl.h>
#endif

#undef lstat
#undef fstat
#undef stat

#include <zstd.h>
#include <zstd_errors.h>
