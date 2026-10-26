/*
 * Authored by Alex Hultman, 2018-2019.
 * Intellectual property of third-party.

 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at

 *     http://www.apache.org/licenses/LICENSE-2.0

 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "internal/internal.h"
#include "libusockets.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <arpa/inet.h>
#include <netinet/in.h>
#endif
#define CONCURRENT_CONNECTIONS 4

#if defined(BUN_DEBUG) || (defined(__has_feature) && __has_feature(address_sanitizer)) || defined(__SANITIZE_ADDRESS__)
#include <assert.h>
#define US_ASSERT(x) assert(x)
#else
#define US_ASSERT(x) ((void)0)
#endif

// clang-format off

/* Forward-declared so this file does not depend on OpenSSL headers. */
/* Opaque SSL_CTX ref helpers — defined in crypto/openssl.c so this file
 * stays free of OpenSSL headers. */

int us_internal_raw_root_certs(struct us_cert_string_t** out);
int us_raw_root_certs(struct us_cert_string_t**out){
    return us_internal_raw_root_certs(out);
}

/* ── Group lifecycle ────────────────────────────────────────────────────── */

void us_socket_group_init(struct us_socket_group_t *group, struct us_loop_t *loop,
                          const struct us_socket_vtable_t *vtable, void *ext) {
    if (!vtable) BUN_PANIC("Socket group requires a callback table");
    US_ASSERT((vtable->retain_group == NULL) == (vtable->release_group == NULL));
    memset(group, 0, sizeof(*group));
    group->loop = loop;
    group->vtable = vtable;
    group->ext = ext;
}

void us_socket_group_deinit(struct us_socket_group_t *group) {
    /* The owner is about to free the embedding storage. Every list head must
     * be empty or some socket/listener/DNS request still
     * holds s->group / c->group / ls->accept_group into us — that's a UAF the
     * caller must close_all() away first. iterator != NULL means we're inside
     * a dispatch on this very group; the on_close that triggers deinit is fine
     * (unlink_socket already advanced iterator), but a re-entrant deinit from
     * inside on_timeout/on_data would tear the floor out from under the sweep. */
    US_ASSERT(group->head_sockets == NULL);
    US_ASSERT(group->head_connecting_sockets == NULL);
    US_ASSERT(group->head_listen_sockets == NULL);
    US_ASSERT(group->iterator == NULL);
    US_ASSERT(group->connecting_iterator == NULL);
    if (group->linked) {
        us_internal_loop_unlink_group(group->loop, group);
        group->linked = 0;
    }
}

/* Close every connecting/connected socket in the group; if `also_listeners`,
 * close listen sockets too. Process-exit callers pass 0: a us_listen_socket_t
 * is 1:1 owned by a Zig Listener / uWS App that holds a raw pointer to it and
 * closes it in finalize(), so closing+freeing it here turns that into a UAF
 * (the original LSAN was only the *accepted* sockets, not the listener). */
void us_socket_group_close_all_ex(struct us_socket_group_t *group, int also_listeners) {
    void (*release_group)(struct us_socket_group_t *) = group->vtable->release_group;
    if (group->vtable->retain_group) group->vtable->retain_group(group);
    if (also_listeners) {
        /* Listeners first — stops new sockets from being accepted into
         * head_sockets while we're draining it. */
        while (group->head_listen_sockets) {
            us_listen_socket_close(group->head_listen_sockets);
        }
    }

    struct us_connecting_socket_t *c = group->head_connecting_sockets;
    while (c) {
        struct us_connecting_socket_t *nextC = c->next_pending;
        us_connecting_socket_close(c);
        c = nextC;
    }

    struct us_socket_t *s = group->head_sockets;
    while (s) {
        struct us_socket_t *nextS = s->next;
        if (us_internal_poll_type(&s->p) & POLL_TYPE_SEMI_SOCKET) {
            /* In-flight connect — close_raw skips dispatch for SEMI_SOCKET
             * (on_close without on_open is wrong), so the Zig wrapper's
             * `socket = .connected` would never detach and finalize() UAFs
             * after drainClosedSockets(). Deliver the same on_connect_error
             * the natural failure path would have, which detaches the
             * wrapper. The handler then closes; if it doesn't, the
             * force-drain below catches it. */
            us_dispatch_connect_error(s, LIBUS_ERR_CONNECTION_ABORTED);
            if (!us_socket_is_closed(s)) {
                us_internal_socket_close_raw(s, LIBUS_SOCKET_CLOSE_CODE_CONNECTION_RESET, 0);
            }
        } else {
            us_socket_close(s, LIBUS_SOCKET_CLOSE_CODE_CLEAN_SHUTDOWN, 0);
        }
        s = nextS;
    }

    /* TLS sockets may have *deferred* the close above: us_internal_ssl_close
     * with code==0 sends close_notify and, on WANT_READ, leaves the socket
     * open in head_sockets waiting for the peer's reply. Callers of close_all
     * (e.g. Listener.deinit) free the embedding storage immediately after, so
     * any survivor's s->group becomes a dangling pointer. The graceful walk
     * already flushed close_notify; force-drain the rest synchronously now. */
    while (group->head_sockets) {
        us_internal_socket_close_raw(group->head_sockets, LIBUS_SOCKET_CLOSE_CODE_CONNECTION_RESET, 0);
    }
    if (release_group) release_group(group);
}

void us_socket_group_close_all(struct us_socket_group_t *group) {
    us_socket_group_close_all_ex(group, 1);
}

unsigned short us_socket_group_timestamp(struct us_socket_group_t *group) {
    return group->timestamp;
}

struct us_loop_t *us_socket_group_loop(struct us_socket_group_t *group) {
    return group->loop;
}

void *us_socket_group_ext(struct us_socket_group_t *group) {
    return group->ext;
}

struct us_socket_group_t *us_socket_group_next(struct us_socket_group_t *group) {
    return group->next;
}

/* ── Link / unlink ──────────────────────────────────────────────────────── */

static inline int us_internal_group_is_empty(struct us_socket_group_t *group) {
    return group->head_sockets == NULL
        && group->head_connecting_sockets == NULL
        && group->head_listen_sockets == NULL;
}

static inline void us_internal_group_touched(struct us_socket_group_t *group) {
    if (!group->linked) {
        us_internal_loop_link_group(group->loop, group);
        group->linked = 1;
    }
}

void us_internal_group_maybe_unlink(struct us_socket_group_t *group) {
    if (group->linked && us_internal_group_is_empty(group)) {
        us_internal_loop_unlink_group(group->loop, group);
        group->linked = 0;
    }
}

void us_internal_socket_group_link_socket(struct us_socket_group_t *group, struct us_socket_t *s) {
    if (us_socket_is_closed(s)) return;

    s->group = group;
    s->next = group->head_sockets;
    s->prev = 0;
    if (group->head_sockets) {
        group->head_sockets->prev = s;
    }
    group->head_sockets = s;
    us_internal_group_touched(group);
}

void us_internal_socket_group_unlink_socket(struct us_socket_group_t *group, struct us_socket_t *s) {
    /* We have to properly update the iterator used to sweep sockets for timeouts */
    if (s == group->iterator) {
        group->iterator = s->next;
    }

    struct us_socket_t* prev = s->prev;
    struct us_socket_t* next = s->next;
    if (prev == next) {
        group->head_sockets = 0;
    } else {
        if (prev) {
            prev->next = next;
        } else {
            group->head_sockets = next;
        }
        if (next) {
            next->prev = prev;
        }
    }
    us_internal_group_maybe_unlink(group);
}

void us_internal_socket_group_link_connecting_socket(struct us_socket_group_t *group, struct us_connecting_socket_t *c) {
    if (c->closed) return;

    c->group = group;
    c->next_pending = group->head_connecting_sockets;
    c->prev_pending = 0;
    if (group->head_connecting_sockets) {
        group->head_connecting_sockets->prev_pending = c;
    }
    group->head_connecting_sockets = c;
    us_internal_group_touched(group);
}

void us_internal_socket_group_unlink_connecting_socket(struct us_socket_group_t *group, struct us_connecting_socket_t *c) {
    if (group->connecting_iterator == c) group->connecting_iterator = c->next_pending;
    struct us_connecting_socket_t* prev = c->prev_pending;
    struct us_connecting_socket_t* next = c->next_pending;
    if (prev == next) {
        group->head_connecting_sockets = 0;
    } else {
        if (prev) {
            prev->next_pending = next;
        } else {
            group->head_connecting_sockets = next;
        }
        if (next) {
            next->prev_pending = prev;
        }
    }
    us_internal_group_maybe_unlink(group);
}

/* ── Adopt ──────────────────────────────────────────────────────────────── */

struct us_socket_t *us_socket_adopt(struct us_socket_t *s, struct us_socket_group_t *group,
                                    unsigned char kind, int old_ext_size, int ext_size) {
    if (us_socket_is_closed(s) || us_socket_is_shut_down(s)) {
        return s;
    }
    struct us_socket_group_t *old_group = s->group;
    struct us_loop_t *loop = old_group->loop;
    if (group->loop != loop) {
        LIBUS_SET_ERR(LIBUS_ERR_INVALID_ARGUMENT);
        return NULL;
    }
    const size_t prefix = sizeof(struct us_socket_t) - sizeof(struct us_poll_t);
    if (s->connect_state || old_ext_size < 0 || ext_size < -1 ||
        (size_t)old_ext_size > UINT_MAX - prefix ||
        (ext_size >= 0 && (size_t)ext_size > UINT_MAX - prefix)) {
        LIBUS_SET_ERR(LIBUS_ERR_INVALID_ARGUMENT);
        return NULL;
    }
    struct us_socket_t *new_s = s;
    if (ext_size != -1) {
        struct us_poll_t *poll_ref = &s->p;
        new_s = (struct us_socket_t *) us_poll_resize(poll_ref, loop,
            sizeof(struct us_socket_t) - sizeof(struct us_poll_t) + old_ext_size,
            sizeof(struct us_socket_t) - sizeof(struct us_poll_t) + ext_size);
        if (!new_s) return NULL;
    }
    us_internal_socket_group_unlink_socket(old_group, s);
    if (new_s != s) {
        s->flags.is_closed = 1;
        s->next = loop->data.closed_head;
        loop->data.closed_head = s;
        s->flags.adopted = 1;
        s->prev = new_s;
    }
    new_s->group = group;
    new_s->kind = kind;
    new_s->timeout = 255;
    new_s->long_timeout = 255;

    if (new_s->flags.low_prio_state == 1) {
        if (!new_s->low_prio_prev) loop->data.low_prio_head = new_s;
        else new_s->low_prio_prev->low_prio_next = new_s;
        if (new_s->low_prio_next) new_s->low_prio_next->low_prio_prev = new_s;
    }
    us_internal_socket_group_link_socket(group, new_s);
    return new_s;
}

/* ── Listen ─────────────────────────────────────────────────────────────── */

static void us_internal_init_listen_socket(struct us_listen_socket_t *ls,
                                           struct us_socket_group_t *group,
                                           unsigned char kind, struct ssl_ctx_st *ssl_ctx,
                                           int options, int socket_ext_size) {
    struct us_socket_t *s = &ls->s;
    s->group = group;
    s->kind = 0; /* listener itself never dispatches */
    s->ssl = NULL;
    s->timeout = 255;
    s->long_timeout = 255;
    s->flags.low_prio_state = 0;
    s->flags.is_paused = 0;
    s->flags.is_ipc = 0;
    s->flags.is_closed = 0;
    s->flags.adopted = 0;
    s->flags.allow_half_open = (options & LIBUS_SOCKET_ALLOW_HALF_OPEN);
    s->next = 0;
    s->prev = 0;
    s->connect_state = NULL;
    s->connect_next = NULL;
    s->low_prio_prev = NULL;
    s->low_prio_next = NULL;

    ls->accept_group = group;
    ls->accept_kind = kind;
    ls->ssl_ctx = ssl_ctx;
    if (ssl_ctx) us_internal_ssl_ctx_up_ref(ssl_ctx);
    ls->sni = NULL;
    ls->on_server_name = NULL;
    ls->socket_ext_size = socket_ext_size;
    ls->deferred_accept = 0;

    /* Link into the group so close_all() / test-isolation can find it. */
    ls->next = group->head_listen_sockets;
    group->head_listen_sockets = ls;
    us_internal_group_touched(group);
}

static struct us_poll_t *create_listen_poll(struct us_socket_group_t *group, int *error) {
    _Static_assert(sizeof(struct us_listen_socket_t) - sizeof(struct us_poll_t) <= UINT_MAX, "listener storage exceeds poll allocator size limit");
    struct us_poll_t *poll = us_create_poll(group->loop, 0, sizeof(struct us_listen_socket_t) - sizeof(struct us_poll_t));
    if (!poll) {
#ifdef _WIN32
        *error = WSA_NOT_ENOUGH_MEMORY;
#else
        *error = ENOMEM;
#endif
    }
    return poll;
}

struct us_listen_socket_t *us_socket_group_listen(struct us_socket_group_t *group,
        unsigned char kind, struct ssl_ctx_st *ssl_ctx,
        const char *host, int port, int options, int socket_ext_size, struct us_listen_error_t *error) {
    *error = (struct us_listen_error_t){0};
    struct us_poll_t *p = create_listen_poll(group, &error->system_error);
    if (!p) return NULL;
    LIBUS_SOCKET_DESCRIPTOR listen_socket_fd = bsd_create_listen_socket(host, port, options, &error->system_error);
    if (listen_socket_fd == LIBUS_SOCKET_ERROR) {
        us_internal_poll_discard(p, group->loop, 0);
        return NULL;
    }

    error->socket_bound = 1;
    us_poll_init(p, listen_socket_fd, POLL_TYPE_SEMI_SOCKET);
    if (us_poll_start(p, group->loop, LIBUS_SOCKET_READABLE, &error->poll_error) != 0) {
        bsd_close_socket(listen_socket_fd);
        us_poll_free(p, group->loop);
        return NULL;
    }

    struct us_listen_socket_t *ls = (struct us_listen_socket_t *) p;
    us_internal_init_listen_socket(ls, group, kind, ssl_ctx, options, socket_ext_size);

    if (options & LIBUS_LISTEN_DEFER_ACCEPT) {
        ls->deferred_accept = bsd_set_defer_accept(listen_socket_fd);
    }

    return ls;
}

struct us_listen_socket_t *us_socket_group_listen_unix(struct us_socket_group_t *group,
        unsigned char kind, struct ssl_ctx_st *ssl_ctx,
        const char *path, size_t pathlen, int options, int socket_ext_size, struct us_listen_error_t *error) {
    *error = (struct us_listen_error_t){0};
    struct us_poll_t *p = create_listen_poll(group, &error->system_error);
    if (!p) return NULL;
    LIBUS_SOCKET_DESCRIPTOR listen_socket_fd = bsd_create_listen_socket_unix(path, pathlen, options, &error->system_error);
    if (listen_socket_fd == LIBUS_SOCKET_ERROR) {
        us_internal_poll_discard(p, group->loop, 0);
        return NULL;
    }

    error->socket_bound = 1;
    us_poll_init(p, listen_socket_fd, POLL_TYPE_SEMI_SOCKET);
    if (us_poll_start(p, group->loop, LIBUS_SOCKET_READABLE, &error->poll_error) != 0) {
        bsd_close_socket(listen_socket_fd);
        us_poll_free(p, group->loop);
        return NULL;
    }

    struct us_listen_socket_t *ls = (struct us_listen_socket_t *) p;
    us_internal_init_listen_socket(ls, group, kind, ssl_ctx, options, socket_ext_size);

    return ls;
}

void us_listen_socket_close(struct us_listen_socket_t *ls) {
    struct us_socket_t *s = &ls->s;
    if (!us_socket_is_closed(s)) {
        struct us_socket_group_t *group = ls->accept_group;
        struct us_loop_t *loop = s->group->loop;
        us_poll_stop((struct us_poll_t *) s, loop);
        bsd_close_socket(us_poll_fd((struct us_poll_t *) s));

        us_internal_listen_socket_ssl_free(ls);

        /* Unlink from group->head_listen_sockets (singly-linked). */
        for (struct us_listen_socket_t **pp = &group->head_listen_sockets; *pp; pp = &(*pp)->next) {
            if (*pp == ls) { *pp = ls->next; break; }
        }
        ls->next = NULL;
        us_internal_group_maybe_unlink(group);

        /* Link this socket to the close-list and let it be deleted after this iteration */
        s->next = loop->data.closed_head;
        loop->data.closed_head = s;
        s->flags.is_closed = 1;
    }
    /* We cannot immediately free a listen socket as we can be inside an accept loop */
}

struct us_listen_socket_t *us_socket_group_head_listen_socket(struct us_socket_group_t *group) {
    return group->head_listen_sockets;
}

struct us_listen_socket_t *us_listen_socket_next(struct us_listen_socket_t *ls) {
    return ls->next;
}

LIBUS_SOCKET_DESCRIPTOR us_listen_socket_get_fd(struct us_listen_socket_t *ls) {
    return us_poll_fd(&ls->s.p);
}

int us_listen_socket_port(struct us_listen_socket_t *ls) {
    return us_socket_local_port(&ls->s);
}

struct us_socket_group_t *us_listen_socket_group(struct us_listen_socket_t *ls) {
    return ls->accept_group;
}

/* ── Connect ────────────────────────────────────────────────────────────── */

static inline void us_internal_init_connect_socket(struct us_socket_t *s,
                                                   struct us_socket_group_t *group,
                                                   unsigned char kind, int options) {
    s->group = group;
    s->kind = kind;
    s->ssl = NULL;
    s->timeout = 255;
    s->long_timeout = 255;
    s->flags.low_prio_state = 0;
    s->flags.allow_half_open = (options & LIBUS_SOCKET_ALLOW_HALF_OPEN);
    s->flags.is_paused = 0;
    s->flags.is_ipc = 0;
    s->flags.is_closed = 0;
    s->flags.adopted = 0;
    s->flags.last_write_failed = 0;
    s->connect_state = NULL;
    s->connect_next = NULL;
    s->low_prio_prev = NULL;
    s->low_prio_next = NULL;
}

struct us_poll_t *us_internal_create_socket_poll(struct us_loop_t *loop, int socket_ext_size) {
    _Static_assert(sizeof(struct us_socket_t) - sizeof(struct us_poll_t) <= UINT_MAX, "socket storage exceeds poll allocator size limit");
    const size_t native_ext_size = sizeof(struct us_socket_t) - sizeof(struct us_poll_t);
    if (socket_ext_size < 0 || (size_t)socket_ext_size > UINT_MAX - native_ext_size) {
#ifdef _WIN32
        LIBUS_SET_ERR(WSAEINVAL);
#else
        LIBUS_SET_ERR(EINVAL);
#endif
        return NULL;
    }
    struct us_poll_t *poll = us_create_poll(loop, 0, (unsigned int)(native_ext_size + (size_t)socket_ext_size));
    if (!poll) {
#ifdef _WIN32
        LIBUS_SET_ERR(WSA_NOT_ENOUGH_MEMORY);
#else
        LIBUS_SET_ERR(ENOMEM);
#endif
    }
    return poll;
}

int us_internal_socket_poll_start(struct us_poll_t *poll, struct us_loop_t *loop, int events, struct us_poll_error_t *failure) {
    if (us_poll_start(poll, loop, events, failure) != 0) return -1;
    if (us_internal_acquire_sweep_timer(loop, failure) != 0) {
        us_poll_stop(poll, loop);
        return -1;
    }
    return 0;
}

static struct us_socket_t *us_socket_group_connect_resolved_dns(struct us_socket_group_t *group,
        unsigned char kind, struct ssl_ctx_st *ssl_ctx,
        struct sockaddr_storage *addr, int options, int socket_ext_size, struct us_connect_error_t *failure) {
    struct us_poll_t *p = us_internal_create_socket_poll(group->loop, socket_ext_size);
    if (!p) {
        failure->system_error = LIBUS_ERR;
        return NULL;
    }
    LIBUS_SOCKET_DESCRIPTOR connect_socket_fd = bsd_create_connect_socket(addr, options);
    if (connect_socket_fd == LIBUS_SOCKET_ERROR) {
        failure->system_error = LIBUS_ERR;
        us_internal_poll_discard(p, group->loop, 0);
        return NULL;
    }

    bsd_socket_nodelay(connect_socket_fd, 1);

    us_poll_init(p, connect_socket_fd, POLL_TYPE_SEMI_SOCKET);
    if (us_internal_socket_poll_start(p, group->loop, LIBUS_SOCKET_WRITABLE, &failure->poll_error) != 0) {
        bsd_close_socket(connect_socket_fd);
        us_poll_free(p, group->loop);
        return NULL;
    }

    struct us_socket_t *socket = (struct us_socket_t *) p;
    us_internal_init_connect_socket(socket, group, kind, options);

    /* Fast path has no us_connecting_socket_t to stash ssl_ctx on, so attach
     * the SSL state now; on_open will see s->ssl != NULL and route through the
     * TLS layer. */
    if (ssl_ctx) {
        us_internal_ssl_attach(socket, ssl_ctx, 1, NULL, NULL);
    }

    us_internal_socket_group_link_socket(group, socket);
    return socket;
}

static void init_addr_with_port(const struct addrinfo* info, int port, struct sockaddr_storage *addr) {
    if (info->ai_family == AF_INET) {
        struct sockaddr_in *addr_in = (struct sockaddr_in *) addr;
        memcpy(addr_in, info->ai_addr, info->ai_addrlen);
        addr_in->sin_port = htons(port);
    } else {
        struct sockaddr_in6 *addr_in6 = (struct sockaddr_in6 *) addr;
        memcpy(addr_in6, info->ai_addr, info->ai_addrlen);
        addr_in6->sin6_port = htons(port);
    }
}

static bool try_parse_ip(const char *ip_str, int port, struct sockaddr_storage *storage) {
    memset(storage, 0, sizeof(struct sockaddr_storage));
    struct sockaddr_in *addr4 = (struct sockaddr_in *)storage;
    if (inet_pton(AF_INET, ip_str, &addr4->sin_addr) == 1) {
        addr4->sin_port = htons(port);
        addr4->sin_family = AF_INET;
#ifdef __APPLE__
        addr4->sin_len = sizeof(struct sockaddr_in);
#endif
        return 1;
    }

    struct sockaddr_in6 *addr6 = (struct sockaddr_in6 *)storage;
    if (inet_pton(AF_INET6, ip_str, &addr6->sin6_addr) == 1) {
        addr6->sin6_port = htons(port);
        addr6->sin6_family = AF_INET6;
#ifdef __APPLE__
        addr6->sin6_len = sizeof(struct sockaddr_in6);
#endif
        return 1;
    }

    return 0;
}

void *us_socket_group_connect(struct us_socket_group_t *group, unsigned char kind,
        struct ssl_ctx_st *ssl_ctx, const char *host, int port, int options,
        int socket_ext_size, int *has_dns_resolved, struct us_connect_error_t *failure) {
    *failure = (struct us_connect_error_t){0};
    *has_dns_resolved = 0;
    struct us_loop_t *loop = group->loop;

    struct sockaddr_storage addr;
    if (try_parse_ip(host, port, &addr)) {
        *has_dns_resolved = 1;
        return us_socket_group_connect_resolved_dns(group, kind, ssl_ctx, &addr, options, socket_ext_size, failure);
    }

    BunDNSRequest *ai_req = NULL;
    uint8_t lookup_status = bun_dns_lookup(loop, host, (uint16_t)port, &ai_req);
    if (lookup_status != BUN_DNS_READY && lookup_status != BUN_DNS_PENDING) {
        failure->system_error = lookup_status == BUN_DNS_OUT_OF_MEMORY ? LIBUS_ERR_OUT_OF_MEMORY : LIBUS_ERR_INVALID_ARGUMENT;
        return NULL;
    }
    if (lookup_status == BUN_DNS_READY) {
        const struct addrinfo *addresses = NULL;
        int error = bun_dns_result(ai_req, &addresses);
        if (error || !addresses) {
            failure->dns_error = error ? error : EAI_NONAME;
            bun_dns_release(ai_req, 1);
            return NULL;
        }

        if (addresses->ai_next == NULL) {
            struct sockaddr_storage a;
            init_addr_with_port(addresses, port, &a);
            *has_dns_resolved = 1;
            struct us_socket_t *s = us_socket_group_connect_resolved_dns(group, kind, ssl_ctx, &a, options, socket_ext_size, failure);
            bun_dns_release(ai_req, s == NULL);
            return s;
        }
    }

    if (socket_ext_size < 0 || (size_t)socket_ext_size > SIZE_MAX - sizeof(struct us_connecting_socket_t)) {
        failure->system_error = LIBUS_ERR_INVALID_ARGUMENT;
        bun_dns_release(ai_req, 0);
        return NULL;
    }
    struct us_connecting_socket_t *c = us_calloc(1, sizeof(struct us_connecting_socket_t) + socket_ext_size);
    if (!c) {
        failure->system_error = LIBUS_ERR_OUT_OF_MEMORY;
        bun_dns_release(ai_req, 0);
        return NULL;
    }
    if (us_internal_acquire_sweep_timer(loop, &failure->poll_error) != 0) {
        us_free(c);
        bun_dns_release(ai_req, 0);
        return NULL;
    }
    c->socket_ext_size = socket_ext_size;
    c->options = options;
    c->kind = kind;
    c->loop = loop;
    c->ssl_ctx = ssl_ctx;
    if (ssl_ctx) us_internal_ssl_ctx_up_ref(ssl_ctx);
    c->timeout = 255;
    c->long_timeout = 255;
    c->pending_resolve_callback = 1;
    c->addrinfo_req = ai_req;
    c->port = port;
    us_internal_socket_group_link_connecting_socket(group, c);

#ifdef _WIN32
    loop->uv_loop->active_handles++;
#else
    loop->num_polls++;
#endif

    if (!bun_dns_subscribe(ai_req, c)) {
#ifdef _WIN32
        loop->uv_loop->active_handles--;
#else
        loop->num_polls--;
#endif
        c->pending_resolve_callback = 0;
        c->addrinfo_req = NULL;
        c->closed = 1;
        bun_dns_release(ai_req, 0);
        us_connecting_socket_free(c);
        failure->system_error = LIBUS_ERR_OUT_OF_MEMORY;
        return NULL;
    }

    return c;
}

struct us_socket_t *us_socket_group_connect_unix(struct us_socket_group_t *group,
        unsigned char kind, struct ssl_ctx_st *ssl_ctx,
        const char *server_path, size_t pathlen, int options, int socket_ext_size, struct us_connect_error_t *failure) {
    *failure = (struct us_connect_error_t){0};
    struct us_poll_t *p = us_internal_create_socket_poll(group->loop, socket_ext_size);
    if (!p) {
        failure->system_error = LIBUS_ERR;
        return NULL;
    }
    LIBUS_SOCKET_DESCRIPTOR connect_socket_fd = bsd_create_connect_socket_unix(server_path, pathlen, options);
    if (connect_socket_fd == LIBUS_SOCKET_ERROR) {
        failure->system_error = LIBUS_ERR;
        us_internal_poll_discard(p, group->loop, 0);
        return NULL;
    }

    us_poll_init(p, connect_socket_fd, POLL_TYPE_SEMI_SOCKET);
    if (us_internal_socket_poll_start(p, group->loop, LIBUS_SOCKET_WRITABLE, &failure->poll_error) != 0) {
        bsd_close_socket(connect_socket_fd);
        us_poll_free(p, group->loop);
        return NULL;
    }

    struct us_socket_t *connect_socket = (struct us_socket_t *) p;
    us_internal_init_connect_socket(connect_socket, group, kind, options);

    if (ssl_ctx) {
        us_internal_ssl_attach(connect_socket, ssl_ctx, 1, NULL, NULL);
    }

    us_internal_socket_group_link_socket(group, connect_socket);
    return connect_socket;
}

int start_connections(struct us_connecting_socket_t *c, int count) {
    int opened = 0;
    struct us_socket_group_t *group = c->group;
    struct us_loop_t *loop = group->loop;
    for (; c->addrinfo_head != NULL && opened < count; c->addrinfo_head = c->addrinfo_head->ai_next) {
        struct sockaddr_storage addr;
        init_addr_with_port(c->addrinfo_head, c->port, &addr);
        struct us_poll_t *poll = us_internal_create_socket_poll(loop, c->socket_ext_size);
        if (!poll) {
            c->failure = (struct us_connect_error_t){.system_error = LIBUS_ERR};
            break;
        }
        LIBUS_SOCKET_DESCRIPTOR connect_socket_fd = bsd_create_connect_socket(&addr, c->options);
        if (connect_socket_fd == LIBUS_SOCKET_ERROR) {
            c->failure = (struct us_connect_error_t){.system_error = LIBUS_ERR};
            us_internal_poll_discard(poll, loop, 0);
            continue;
        }
        bsd_socket_nodelay(connect_socket_fd, 1);
        struct us_socket_t *s = (struct us_socket_t *)poll;
        us_poll_init(poll, connect_socket_fd, POLL_TYPE_SEMI_SOCKET);
        struct us_poll_error_t poll_error;
        if (us_internal_socket_poll_start(poll, loop, LIBUS_SOCKET_WRITABLE, &poll_error) != 0) {
            c->failure = (struct us_connect_error_t){.poll_error = poll_error};
            bsd_close_socket(connect_socket_fd);
            us_poll_free(poll, loop);
            continue;
        }
        ++opened;
        us_internal_init_connect_socket(s, group, c->kind, c->options);

        us_internal_socket_group_link_socket(group, s);

        memcpy((void *)(s + 1), (void *)(c + 1), c->socket_ext_size);

        s->connect_next = c->connecting_head;
        c->connecting_head = s;
        s->connect_state = c;

    }
    return opened;
}

void us_internal_socket_after_resolve(struct us_connecting_socket_t *c) {
    /* close_all() may have run between the DNS thread queuing this callback and
     * us reaching it; c->group is NULL'd at close so it can't be touched. The
     * keep-alive (num_polls/active_handles) was already balanced by the close
     * cancellation path. */
    c->pending_resolve_callback = 0;
    if (c->closed) {
        if (c->addrinfo_req) {
            bun_dns_release(c->addrinfo_req, 0);
            c->addrinfo_req = 0;
        }
        us_connecting_socket_free(c);
        return;
    }

    struct us_socket_group_t *group = c->group;
#ifdef _WIN32
    group->loop->uv_loop->active_handles--;
#else
    group->loop->num_polls--;
#endif
    int error = bun_dns_result(c->addrinfo_req, &c->addrinfo_head);
    if (error || !c->addrinfo_head) {
        c->failure = (struct us_connect_error_t){.dns_error = error ? error : EAI_NONAME};
        us_connecting_socket_close(c);
        return;
    }

    int opened = start_connections(c, CONCURRENT_CONNECTIONS);
    if (opened == 0) {
        us_connecting_socket_close(c);
    }
}

void us_internal_socket_after_open(struct us_socket_t *s) {
    struct us_connecting_socket_t *c = s->connect_state;
    const int error = bsd_socket_error(us_poll_fd(&s->p));
    if (error) {
        if (c) {
            c->failure = (struct us_connect_error_t){.system_error = error};
            for (struct us_socket_t **next = &c->connecting_head; *next; next = &(*next)->connect_next) {
                if (*next == s) {
                    *next = s->connect_next;
                    break;
                }
            }
            us_socket_close(s, LIBUS_SOCKET_CLOSE_CODE_CONNECTION_RESET, 0);

            if (c->connecting_head == NULL || c->connecting_head->connect_next == NULL) {
                int opened = start_connections(c, c->connecting_head == NULL ? CONCURRENT_CONNECTIONS : 1);
                if (opened == 0 && c->connecting_head == NULL) {
                    us_connecting_socket_close(c);
                }
            }
        } else {
            us_dispatch_connect_error(s, error);
            // It's expected that close is called by the caller
        }
    } else {
        us_poll_change(&s->p, s->group->loop, LIBUS_SOCKET_READABLE);
        bsd_socket_nodelay(us_poll_fd(&s->p), 1);
        us_internal_poll_set_type(&s->p, POLL_TYPE_SOCKET);
        us_socket_timeout(s, 0);

        if (c) {
            s->long_timeout = c->long_timeout;
            for (struct us_socket_t *next = c->connecting_head; next; next = next->connect_next) {
                if (next != s) {
                    us_socket_close(next, LIBUS_SOCKET_CLOSE_CODE_CONNECTION_RESET, 0);
                }
            }
            /* Attach TLS now that we know which candidate won. */
            if (c->ssl_ctx) {
                us_internal_ssl_attach(s, c->ssl_ctx, 1, NULL, NULL);
            }
            bun_dns_release(c->addrinfo_req, 0);
            us_connecting_socket_free(c);
            s->connect_state = NULL;
        }

        if (s->ssl) {
            us_internal_ssl_on_open(s, 1, 0, 0);
        } else {
            us_dispatch_open(s, 1, 0, 0);
        }
    }
}

/* ── Misc ───────────────────────────────────────────────────────────────── */

struct us_bun_verify_error_t us_socket_verify_error(struct us_socket_t *s) {
    if (s->ssl) {
        return us_internal_ssl_verify_error(s);
    }
    return (struct us_bun_verify_error_t) { .error = 0, .code = NULL, .reason = NULL };
}
