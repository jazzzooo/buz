#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "BunSpawn.h"

#if defined(__linux__) || defined(__APPLE__) || defined(__FreeBSD__)
#include "BunCloseRange.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/prctl.h>
#endif

extern char** environ;

#if defined(__linux__) && defined(__GLIBC__)
#if __GLIBC_PREREQ(2, 34)
#define BUN_SPAWN_CLOSEFROM 1
#endif
#endif

int32_t bun_wait_child_exit(int32_t pid)
{
    siginfo_t info;
    while (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) < 0) {
        if (errno != EINTR) return errno;
    }
    return 0;
}

static int validateRequest(const BunSpawnRequest* request)
{
    if (request->detached > 1 || request->new_process_group > 1 || request->reset_signals > 1
        || request->pty_slave_fd < -1 || request->linux_pdeathsig < 0 || request->linux_pdeathsig >= NSIG
        || (request->actions_len && !request->actions))
        return EINVAL;
#if !defined(__linux__)
    if (request->linux_pdeathsig) return ENOTSUP;
#endif
    for (size_t i = 0; i < request->actions_len; i++) {
        const BunSpawnAction* action = &request->actions[i];
        if (action->fds[0] < 0) return EBADF;
        switch (action->kind) {
        case BUN_SPAWN_CLOSE:
            break;
        case BUN_SPAWN_DUP2:
            if (action->fds[1] < 0) return EBADF;
            break;
        case BUN_SPAWN_OPEN:
            if (!action->path) return EINVAL;
            break;
        default:
            return EINVAL;
        }
    }
    return 0;
}

#if defined(__APPLE__) || defined(BUN_SPAWN_CLOSEFROM)
#if defined(BUN_SPAWN_CLOSEFROM)
static int closeUninheritedFDs(posix_spawn_file_actions_t* actions, const BunSpawnRequest* request)
{
    int maximum = 2;
    for (size_t i = 0; i < request->actions_len; i++) {
        const BunSpawnAction* action = &request->actions[i];
        int destination = action->kind == BUN_SPAWN_DUP2 ? action->fds[1]
            : action->kind == BUN_SPAWN_OPEN ? action->fds[0] : -1;
        if (destination > maximum) maximum = destination;
    }

    // Close sources only after all ordered actions have consumed them. Explicit
    // destinations may be sparse, so close their gaps as well as the trailing range.
    for (int fd = 3; fd < maximum; fd++) {
        bool inherited = false;
        for (size_t i = 0; i < request->actions_len; i++) {
            const BunSpawnAction* action = &request->actions[i];
            if ((action->kind == BUN_SPAWN_DUP2 && action->fds[1] == fd)
                || (action->kind == BUN_SPAWN_OPEN && action->fds[0] == fd)) {
                inherited = true;
                break;
            }
        }
        if (!inherited) {
            int result = posix_spawn_file_actions_addclose(actions, fd);
            if (result) return result;
        }
    }
    return maximum < INT_MAX ? posix_spawn_file_actions_addclosefrom_np(actions, maximum + 1) : 0;
}
#endif

static int spawnWithSystem(pid_t* pid, const char* path, const BunSpawnRequest* request,
    char* const argv[], char* const envp[])
{
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int result = posix_spawnattr_init(&attr);
    if (result) return result;
    result = posix_spawn_file_actions_init(&actions);
    if (result) {
        posix_spawnattr_destroy(&attr);
        return result;
    }

    short flags = request->flags;
#if defined(__APPLE__)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if (request->detached) flags |= POSIX_SPAWN_SETSID;
    if (request->new_process_group && !request->detached) {
        flags |= POSIX_SPAWN_SETPGROUP;
        result = posix_spawnattr_setpgroup(&attr, 0);
        if (result) goto done;
    }
    if (request->reset_signals) flags |= POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    if (flags & POSIX_SPAWN_SETSIGDEF) {
        sigset_t defaults;
        sigfillset(&defaults);
        result = posix_spawnattr_setsigdefault(&attr, &defaults);
        if (result) goto done;
    }
    if (flags & POSIX_SPAWN_SETSIGMASK) {
        sigset_t mask;
        sigemptyset(&mask);
        result = posix_spawnattr_setsigmask(&attr, &mask);
        if (result) goto done;
    }
    result = posix_spawnattr_setflags(&attr, flags);
    if (result) goto done;

    if (request->cwd) {
        result = posix_spawn_file_actions_addchdir_np(&actions, request->cwd);
        if (result) goto done;
    }
    for (size_t i = 0; i < request->actions_len; i++) {
        const BunSpawnAction* action = &request->actions[i];
        switch (action->kind) {
        case BUN_SPAWN_CLOSE:
            result = posix_spawn_file_actions_addclose(&actions, action->fds[0]);
            break;
        case BUN_SPAWN_DUP2:
#if defined(__APPLE__)
            if (action->fds[0] == action->fds[1])
                result = posix_spawn_file_actions_addinherit_np(&actions, action->fds[0]);
            else
#endif
                result = posix_spawn_file_actions_adddup2(&actions, action->fds[0], action->fds[1]);
            break;
        case BUN_SPAWN_OPEN:
            result = posix_spawn_file_actions_addopen(&actions, action->fds[0], action->path,
                action->flags & ~O_CLOEXEC, action->mode);
            break;
        }
        if (result) goto done;
    }
#if defined(BUN_SPAWN_CLOSEFROM)
    result = closeUninheritedFDs(&actions, request);
    if (result) goto done;
#endif
    result = posix_spawn(pid, path, &actions, &attr, argv, envp);
done:
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    return result;
}
#endif

static bool actionUsesFD(const BunSpawnRequest* request, int fd)
{
    if (request->pty_slave_fd == fd) return true;
    for (size_t i = 0; i < request->actions_len; i++) {
        const BunSpawnAction* action = &request->actions[i];
        if (action->fds[0] == fd || (action->kind == BUN_SPAWN_DUP2 && action->fds[1] == fd)) return true;
    }
    return false;
}

static int duplicatePrivateFD(int fd, const BunSpawnRequest* request)
{
    int minimum = 3;
    for (;;) {
        int result;
        do {
            result = fcntl(fd, F_DUPFD_CLOEXEC, minimum);
        } while (result < 0 && errno == EINTR);
        if (result < 0 || !actionUsesFD(request, result)) return result;
        close(result);
        if (result == INT_MAX) {
            errno = EMFILE;
            return -1;
        }
        minimum = result + 1;
    }
}

static int createErrorPipe(int out[2], const BunSpawnRequest* request)
{
    int pipeFDs[2];
#if defined(__linux__) || defined(__FreeBSD__)
    if (pipe2(pipeFDs, O_CLOEXEC) < 0) return errno;
#else
    if (pipe(pipeFDs) < 0) return errno;
#endif
    // Keep both ends outside every action operand, including initially closed
    // descriptors. Otherwise a bad dup source could become the error pipe.
    int reader = duplicatePrivateFD(pipeFDs[0], request);
    int failure = reader < 0 ? errno : 0;
    int writer = failure ? -1 : duplicatePrivateFD(pipeFDs[1], request);
    if (writer < 0 && !failure) failure = errno;
    close(pipeFDs[0]);
    close(pipeFDs[1]);
    if (failure) {
        if (reader >= 0) close(reader);
        return failure;
    }
    out[0] = reader;
    out[1] = writer;
    return 0;
}

static int inheritFD(int source, int destination)
{
    int result;
    if (source != destination) {
        do {
            result = dup2(source, destination);
        } while (result < 0 && errno == EINTR);
        return result < 0 ? errno : 0;
    }
    int flags;
    do {
        flags = fcntl(source, F_GETFD);
    } while (flags < 0 && errno == EINTR);
    if (flags < 0) return errno;
    do {
        result = fcntl(source, F_SETFD, flags & ~FD_CLOEXEC);
    } while (result < 0 && errno == EINTR);
    return result < 0 ? errno : 0;
}

static int configureChild(const BunSpawnRequest* request, const sigset_t* oldMask, pid_t parent)
{
    struct sigaction action = { 0 };
    sigemptyset(&action.sa_mask);
    const bool resetSignals = request->reset_signals || (request->flags & POSIX_SPAWN_SETSIGDEF);
    for (int signal = 1; signal < NSIG; signal++) {
        if (signal == SIGKILL || signal == SIGSTOP) continue;
        struct sigaction previous;
        if (sigaction(signal, NULL, &previous) < 0) {
            // Libc reserves some signal numbers for its threading runtime.
            if (errno == EINVAL) continue;
            return errno;
        }
        if (resetSignals || previous.sa_handler != SIG_IGN) {
            action.sa_handler = SIG_DFL;
            if (sigaction(signal, &action, NULL) < 0) return errno;
        }
    }

    if (request->detached || request->pty_slave_fd >= 0) {
        if (setsid() < 0) return errno;
    } else if (request->new_process_group || (request->flags & POSIX_SPAWN_SETPGROUP)) {
        if (setpgid(0, 0) < 0) return errno;
    }
#if defined(__linux__)
    if (request->linux_pdeathsig) {
        if (prctl(PR_SET_PDEATHSIG, request->linux_pdeathsig, 0, 0, 0) < 0) return errno;
        if (getppid() != parent) return ECANCELED;
    }
#else
    (void)parent;
#endif
    if (request->pty_slave_fd >= 0 && ioctl(request->pty_slave_fd, TIOCSCTTY, 0) < 0) return errno;
    if (request->cwd && chdir(request->cwd) < 0) return errno;

    // Mark all inherited descriptors before actions. Each explicit open or dup
    // clears CLOEXEC, including destinations below another action's maximum fd.
    if (bun_close_range(3, UINT32_MAX, BUN_CLOSE_RANGE_CLOEXEC) < 0) return errno;
    for (size_t i = 0; i < request->actions_len; i++) {
        const BunSpawnAction* fileAction = &request->actions[i];
        int result;
        switch (fileAction->kind) {
        case BUN_SPAWN_CLOSE:
            if (close(fileAction->fds[0]) < 0 && errno != EBADF) return errno;
            break;
        case BUN_SPAWN_DUP2:
            result = inheritFD(fileAction->fds[0], fileAction->fds[1]);
            if (result) return result;
            break;
        case BUN_SPAWN_OPEN: {
            if (close(fileAction->fds[0]) < 0 && errno != EBADF) return errno;
            int opened;
            do {
                opened = open(fileAction->path, fileAction->flags | O_CLOEXEC, fileAction->mode);
            } while (opened < 0 && errno == EINTR);
            if (opened < 0) return errno;
            result = inheritFD(opened, fileAction->fds[0]);
            if (opened != fileAction->fds[0]) close(opened);
            if (result) return result;
            break;
        }
        }
    }

    sigset_t mask = *oldMask;
    if (request->reset_signals || (request->flags & POSIX_SPAWN_SETSIGMASK)) sigemptyset(&mask);
    if (sigprocmask(SIG_SETMASK, &mask, NULL) < 0) return errno;
    return 0;
}

static _Noreturn void childFailed(int pipeFD, int failure)
{
    const unsigned char* bytes = (const unsigned char*)&failure;
    size_t remaining = sizeof(failure);
    while (remaining) {
        ssize_t written = write(pipeFD, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) break;
        bytes += written;
        remaining -= written;
    }
    _exit(127);
}

static void reapFailedChild(pid_t child)
{
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) { }
}

static int spawnWithFork(pid_t* pid, const char* path, const BunSpawnRequest* request,
    char* const argv[], char* const envp[])
{
#if defined(__APPLE__)
    if (request->flags & POSIX_SPAWN_SETEXEC) return ENOTSUP;
#endif
    int cancellation;
    int result = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cancellation);
    if (result) return result;
    int pipeFDs[2];
    result = createErrorPipe(pipeFDs, request);
    if (result) goto restoreCancellation;

    sigset_t blocked, previous;
    sigfillset(&blocked);
    result = pthread_sigmask(SIG_SETMASK, &blocked, &previous);
    if (result) goto closePipe;

    const pid_t parent = getpid();
    pid_t child = fork();
    if (child == 0) {
        close(pipeFDs[0]);
        int failure = configureChild(request, &previous, parent);
        if (!failure) {
            execve(path, argv, envp);
            failure = errno;
        }
        childFailed(pipeFDs[1], failure);
    }

    result = child < 0 ? errno : 0;
    close(pipeFDs[1]);
    pipeFDs[1] = -1;
    if (child > 0) {
        int failure = 0;
        size_t received = 0;
        while (received < sizeof(failure)) {
            ssize_t count = read(pipeFDs[0], (unsigned char*)&failure + received, sizeof(failure) - received);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) {
                result = errno;
                break;
            }
            if (!count) break;
            received += count;
        }
        if (!result && received) result = received == sizeof(failure) && failure > 0 ? failure : EIO;
        if (result) {
            if (received != sizeof(failure)) kill(child, SIGKILL);
            reapFailedChild(child);
        } else {
            *pid = child;
        }
    }
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
closePipe:
    close(pipeFDs[0]);
    if (pipeFDs[1] >= 0) close(pipeFDs[1]);
restoreCancellation:
    pthread_setcancelstate(cancellation, NULL);
    return result;
}

int32_t bun_spawn(int32_t* pid, const char* path, const BunSpawnRequest* request,
    const char* const argv[], const char* const envp[])
{
    if (!pid || !path || !request || !argv) return EINVAL;
    int result = validateRequest(request);
    if (result) return result;
    pid_t child;
#if defined(__APPLE__) || defined(BUN_SPAWN_CLOSEFROM)
    if (request->pty_slave_fd < 0 && !request->linux_pdeathsig)
        result = spawnWithSystem(&child, path, request, (char* const*)argv, envp ? (char* const*)envp : environ);
    else
#endif
        result = spawnWithFork(&child, path, request, (char* const*)argv, envp ? (char* const*)envp : environ);
    if (!result) *pid = child;
    return result;
}
#endif
