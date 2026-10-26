#include "internal/internal.h"
#ifndef _WIN32
#include <unistd.h>
#endif

struct us_socket_t *us_dispatch_open(struct us_socket_t *s, int is_client, char *ip, int length) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    return callbacks->on_open ? callbacks->on_open(s, is_client, ip, length) : s;
}

struct us_socket_t *us_dispatch_data(struct us_socket_t *s, char *data, int length) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    return callbacks->on_data ? callbacks->on_data(s, data, length) : s;
}

struct us_socket_t *us_dispatch_fd(struct us_socket_t *s, int fd) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    if (callbacks->on_fd) return callbacks->on_fd(s, fd);
#ifndef _WIN32
    close(fd);
#endif
    return s;
}

struct us_socket_t *us_dispatch_writable(struct us_socket_t *s) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    return callbacks->on_writable ? callbacks->on_writable(s) : s;
}

struct us_socket_t *us_dispatch_close(struct us_socket_t *s, int code, void *reason) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    return callbacks->on_close ? callbacks->on_close(s, code, reason) : s;
}

struct us_socket_t *us_dispatch_timeout(struct us_socket_t *s) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    return callbacks->on_timeout ? callbacks->on_timeout(s) : s;
}

struct us_socket_t *us_dispatch_long_timeout(struct us_socket_t *s) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    return callbacks->on_long_timeout ? callbacks->on_long_timeout(s) : s;
}

struct us_socket_t *us_dispatch_end(struct us_socket_t *s) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    return callbacks->on_end ? callbacks->on_end(s) : s;
}

struct us_socket_t *us_dispatch_connect_error(struct us_socket_t *s, int code) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    const struct us_connect_error_t failure = {.system_error = code};
    return callbacks->on_connect_error ? callbacks->on_connect_error(s, &failure) : s;
}

void us_dispatch_connecting_timeout(struct us_connecting_socket_t *s, int long_timeout) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    void (*callback)(struct us_connecting_socket_t *) = long_timeout
        ? callbacks->on_connecting_long_timeout : callbacks->on_connecting_timeout;
    if (!callback) return;
    us_internal_connecting_socket_begin_callback(s);
    callback(s);
    us_internal_connecting_socket_end_callback(s);
}

void us_dispatch_handshake(struct us_socket_t *s, int success, struct us_bun_verify_error_t error) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    if (callbacks->on_handshake) callbacks->on_handshake(s, success, error, NULL);
}

struct us_socket_t *us_dispatch_ssl_raw_tap(struct us_socket_t *s, char *data, int length) {
    const struct us_socket_vtable_t *callbacks = s->group->vtable;
    return callbacks->on_ssl_raw_data ? callbacks->on_ssl_raw_data(s, data, length) : s;
}
