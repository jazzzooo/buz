#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    BUN_SPAWN_CLOSE = 1,
    BUN_SPAWN_DUP2 = 2,
    BUN_SPAWN_OPEN = 3,
};

typedef struct BunSpawnAction {
    uint8_t kind;
    const char* path;
    int32_t fds[2];
    int32_t flags;
    uint32_t mode;
} BunSpawnAction;

typedef struct BunSpawnRequest {
    const char* cwd;
    const BunSpawnAction* actions;
    size_t actions_len;
    int32_t pty_slave_fd;
    int32_t linux_pdeathsig;
    uint16_t flags;
    uint8_t detached;
    uint8_t new_process_group;
    uint8_t reset_signals;
} BunSpawnRequest;

// All inputs are borrowed until return. On success, pid owns a child to reap;
// on failure, pid is unchanged and the function returns a POSIX errno.
int32_t bun_spawn(int32_t* pid, const char* path, const BunSpawnRequest* request,
    const char* const argv[], const char* const envp[]);

// Observes exit without consuming the child's wait status or releasing its PID.
int32_t bun_wait_child_exit(int32_t pid);

#ifdef __cplusplus
}
#endif
