/*
 * Authored by Alex Hultman, 2018-2021.
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
#include <stdlib.h>

#ifdef LIBUS_USE_LIBUV

/* uv_poll_t->data always (except for most times after calling us_poll_stop)
 * points to the us_poll_t */
static void poll_cb(uv_poll_t *p, int status, int events) {
  us_internal_dispatch_ready_poll((struct us_poll_t *)p->data, status < 0 && status != UV_EOF, status == UV_EOF,
                                  events);
}

static void prepare_cb(uv_prepare_t *p) {
  struct us_loop_t *loop = p->data;
  us_internal_loop_pre(loop);
}

/* Note: libuv timers execute AFTER the post callback */
static void check_cb(uv_check_t *p) {
  struct us_loop_t *loop = p->data;
  us_internal_loop_post(loop);
}

/* Not used for polls, since polls need two frees */
static void close_cb_free(uv_handle_t *h) { free(h->data); }

/* This one is different for polls, since we need two frees here */
static void close_cb_free_poll(uv_handle_t *h) {
  struct us_poll_t *p = h->data;
  p->uv_p = NULL;
  p->uv_initialized = 0;
  free(h);
  if (p->free_requested) free(p);
}

static void timer_cb(uv_timer_t *t) {
  struct us_internal_callback_t *cb = t->data;
  cb->cb(cb->loop);
}

static void async_cb(uv_async_t *a) {
  struct us_internal_callback_t *cb = a->data;
  if (cb->cb) cb->cb(cb->loop);
}

// poll
void us_poll_init(struct us_poll_t *p, LIBUS_SOCKET_DESCRIPTOR fd,
                  int poll_type) {
  p->poll_type = poll_type;
  p->fd = fd;
}

void us_poll_free(struct us_poll_t *p, struct us_loop_t *loop) {
  (void)loop;
  if (!p->uv_initialized) {
    free(p->uv_p);
    free(p);
    return;
  }
  p->free_requested = 1;
  if (!uv_is_closing((uv_handle_t *)p->uv_p)) uv_close((uv_handle_t *)p->uv_p, close_cb_free_poll);
}

int us_poll_start(struct us_poll_t *p, struct us_loop_t *loop, int events, struct us_poll_error_t *error) {
  *error = (struct us_poll_error_t){US_POLL_ERROR_NONE, 0};
  if (!p->uv_p || p->uv_initialized || p->free_requested) {
    *error = (struct us_poll_error_t){US_POLL_ERROR_LIBUV, UV_EINVAL};
    return -1;
  }
  int result = uv_poll_init_socket(loop->uv_loop, p->uv_p, p->fd);
  if (result != 0) {
    *error = (struct us_poll_error_t){US_POLL_ERROR_LIBUV, result};
    return -1;
  }
  p->uv_initialized = 1;
  p->uv_p->data = p;
  uv_unref((uv_handle_t *)p->uv_p);
  result = uv_poll_start(p->uv_p, events, poll_cb);
  if (result != 0) {
    *error = (struct us_poll_error_t){US_POLL_ERROR_LIBUV, result};
    return -1;
  }
  p->poll_type = us_internal_poll_type(p) |
                 ((events & LIBUS_SOCKET_READABLE) ? POLL_TYPE_POLLING_IN : 0) |
                 ((events & LIBUS_SOCKET_WRITABLE) ? POLL_TYPE_POLLING_OUT : 0);
  return 0;
}

void us_poll_change(struct us_poll_t *p, struct us_loop_t *loop, int events) {
  if(!p->uv_p) return;
  if (us_poll_events(p) != events) {
    p->poll_type =
        us_internal_poll_type(p) |
        ((events & LIBUS_SOCKET_READABLE) ? POLL_TYPE_POLLING_IN : 0) |
        ((events & LIBUS_SOCKET_WRITABLE) ? POLL_TYPE_POLLING_OUT : 0);
    uv_poll_start(p->uv_p, events, poll_cb);
  }
}

void us_poll_stop(struct us_poll_t *p, struct us_loop_t *loop) {
  (void)loop;
  if (!p->uv_initialized || uv_is_closing((uv_handle_t *)p->uv_p)) return;
  uv_poll_stop(p->uv_p);
  p->poll_type = us_internal_poll_type(p);
  uv_close((uv_handle_t *)p->uv_p, close_cb_free_poll);
}

int us_poll_events(struct us_poll_t *p) {
  return ((p->poll_type & POLL_TYPE_POLLING_IN) ? LIBUS_SOCKET_READABLE : 0) |
         ((p->poll_type & POLL_TYPE_POLLING_OUT) ? LIBUS_SOCKET_WRITABLE : 0);
}

size_t us_internal_accept_poll_event(struct us_poll_t *p) { return 0; }

int us_internal_poll_type(struct us_poll_t *p) { return p->poll_type & POLL_TYPE_KIND_MASK; }

void us_internal_poll_set_type(struct us_poll_t *p, int poll_type) {
  p->poll_type = poll_type | (p->poll_type & POLL_TYPE_POLLING_MASK);
}

LIBUS_SOCKET_DESCRIPTOR us_poll_fd(struct us_poll_t *p) { return p->fd; }

void us_loop_pump(struct us_loop_t *loop) {
  uv_run(loop->uv_loop, UV_RUN_NOWAIT);
}

struct us_loop_t *us_create_loop(void *hint,
                                 void (*wakeup_cb)(struct us_loop_t *loop),
                                 void (*pre_cb)(struct us_loop_t *loop),
                                 void (*post_cb)(struct us_loop_t *loop),
                                 unsigned int ext_size, struct us_poll_error_t *failure) {
  *failure = (struct us_poll_error_t){0};
  size_t allocation_size;
  if (__builtin_add_overflow(sizeof(struct us_loop_t), (size_t) ext_size, &allocation_size)) {
    *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = UV_EINVAL};
    return NULL;
  }
  struct us_loop_t *loop =
      (struct us_loop_t *)calloc(1, allocation_size);
  if (!loop) {
    *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = UV_ENOMEM};
    return NULL;
  }

  loop->is_default = hint != 0;
  int result;
  if (hint) {
    loop->uv_loop = hint;
  } else {
    loop->uv_loop = malloc(sizeof(uv_loop_t));
    if (!loop->uv_loop) {
      *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = UV_ENOMEM};
      free(loop);
      return NULL;
    }
    result = uv_loop_init(loop->uv_loop);
    if (result != 0) {
      *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = result};
      free(loop->uv_loop);
      free(loop);
      return NULL;
    }
  }

  int pre_initialized = 0;
  int check_initialized = 0;

  loop->uv_pre = malloc(sizeof(uv_prepare_t));
  if (!loop->uv_pre) goto out_of_memory;
  result = uv_prepare_init(loop->uv_loop, loop->uv_pre);
  if (result != 0) goto uv_failure;
  pre_initialized = 1;
  result = uv_prepare_start(loop->uv_pre, prepare_cb);
  if (result != 0) goto uv_failure;
  uv_unref((uv_handle_t *)loop->uv_pre);
  loop->uv_pre->data = loop;

  loop->uv_check = malloc(sizeof(uv_check_t));
  if (!loop->uv_check) goto out_of_memory;
  result = uv_check_init(loop->uv_loop, loop->uv_check);
  if (result != 0) goto uv_failure;
  check_initialized = 1;
  uv_unref((uv_handle_t *)loop->uv_check);
  result = uv_check_start(loop->uv_check, check_cb);
  if (result != 0) goto uv_failure;
  loop->uv_check->data = loop;

  // here we create two unreffed handles - timer and async
  if (us_internal_loop_data_init(loop, wakeup_cb, pre_cb, post_cb, failure) != 0) goto cleanup;

  return loop;

out_of_memory:
  result = UV_ENOMEM;
uv_failure:
  *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = result};
cleanup:
  if (pre_initialized) {
    uv_prepare_stop(loop->uv_pre);
    loop->uv_pre->data = loop->uv_pre;
    uv_close((uv_handle_t *)loop->uv_pre, close_cb_free);
  } else {
    free(loop->uv_pre);
  }
  if (check_initialized) {
    uv_check_stop(loop->uv_check);
    loop->uv_check->data = loop->uv_check;
    uv_close((uv_handle_t *)loop->uv_check, close_cb_free);
  } else {
    free(loop->uv_check);
  }
  if (!loop->is_default) {
    uv_run(loop->uv_loop, UV_RUN_NOWAIT);
    uv_loop_delete(loop->uv_loop);
  }
  free(loop);
  return NULL;
}

// based on if this was default loop or not
void us_loop_free(struct us_loop_t *loop) {
  // ref and close down prepare and check
  uv_ref((uv_handle_t *)loop->uv_pre);
  uv_prepare_stop(loop->uv_pre);
  loop->uv_pre->data = loop->uv_pre;
  uv_close((uv_handle_t *)loop->uv_pre, close_cb_free);

  uv_ref((uv_handle_t *)loop->uv_check);
  uv_check_stop(loop->uv_check);
  loop->uv_check->data = loop->uv_check;
  uv_close((uv_handle_t *)loop->uv_check, close_cb_free);

  us_internal_loop_data_free(loop);

  // we need to run the loop one last round to call all close callbacks
  // we cannot do this if we do not own the loop, default
  if (!loop->is_default) {
    uv_run(loop->uv_loop, UV_RUN_NOWAIT);
    uv_loop_delete(loop->uv_loop);
  }

  // now we can free our part
  free(loop);
}

void us_loop_run(struct us_loop_t *loop) {
  uv_update_time(loop->uv_loop);

  uv_run(loop->uv_loop, UV_RUN_ONCE);
}

struct us_poll_t *us_create_poll(struct us_loop_t *loop, int fallthrough,
                                 unsigned int ext_size) {
  struct us_poll_t *p =
      (struct us_poll_t *)malloc(sizeof(struct us_poll_t) + ext_size);
  if (!p) return NULL;
  p->uv_p = malloc(sizeof(uv_poll_t));
  if (!p->uv_p) {
    free(p);
    return NULL;
  }
  p->uv_p->data = p;
  p->uv_initialized = 0;
  p->free_requested = 0;
  return p;
}

void us_internal_poll_discard(struct us_poll_t *p, struct us_loop_t *loop, int fallthrough) {
  (void)loop;
  (void)fallthrough;
  free(p->uv_p);
  free(p);
}

/* If we update our block position we have to update the uv_poll data to point
 * to us */
struct us_poll_t *us_poll_resize(struct us_poll_t *p, struct us_loop_t *loop,
                                 unsigned int old_ext_size, unsigned int ext_size) {

  const size_t old_size = sizeof(struct us_poll_t) + (size_t)old_ext_size;
  const size_t new_size = sizeof(struct us_poll_t) + (size_t)ext_size;
  if(new_size <= old_size) return p;
  if (!p->uv_p || !p->uv_initialized || p->free_requested || uv_is_closing((uv_handle_t *)p->uv_p)) {
    LIBUS_SET_ERR(LIBUS_ERR_INVALID_ARGUMENT);
    return NULL;
  }

  struct us_poll_t *new_p = calloc(1, new_size);
  if (!new_p) {
    LIBUS_SET_ERR(LIBUS_ERR_OUT_OF_MEMORY);
    return NULL;
  }
  memcpy(new_p, p, old_size);

  new_p->uv_p->data = new_p;
  p->uv_p = NULL;
  p->uv_initialized = 0;

  return new_p;
}

// timer
struct us_timer_t *us_internal_create_timer(struct us_loop_t *loop, void (*callback)(struct us_loop_t *), struct us_poll_error_t *failure) {
  *failure = (struct us_poll_error_t){0};
  struct us_internal_callback_t *cb = us_calloc(
      1, sizeof(struct us_internal_callback_t) + sizeof(uv_timer_t));
  if (!cb) {
    *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = UV_ENOMEM};
    return NULL;
  }

  cb->loop = loop;
  cb->cb = callback;

  uv_timer_t *uv_timer = (uv_timer_t *)(cb + 1);
  const int result = uv_timer_init(loop->uv_loop, uv_timer);
  if (result != 0) {
    *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = result};
    us_free(cb);
    return NULL;
  }
  uv_timer->data = cb;

  uv_unref((uv_handle_t *)uv_timer);

  return (struct us_timer_t *)cb;
}

void us_internal_timer_close(struct us_timer_t *t) {
  struct us_internal_callback_t *cb = (struct us_internal_callback_t *)t;

  uv_timer_t *uv_timer = (uv_timer_t *)(cb + 1);

  // always ref the timer before closing it
  uv_ref((uv_handle_t *)uv_timer);

  uv_timer_stop(uv_timer);

  uv_timer->data = cb;
  uv_close((uv_handle_t *)uv_timer, close_cb_free);
}

int us_internal_timer_set(struct us_timer_t *t, int ms, int repeat_ms, struct us_poll_error_t *failure) {
  *failure = (struct us_poll_error_t){0};
  if (ms < 0 || repeat_ms < 0) {
    *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = UV_EINVAL};
    return -1;
  }
  struct us_internal_callback_t *internal_cb =
      (struct us_internal_callback_t *)t;

  uv_timer_t *uv_timer = (uv_timer_t *)(internal_cb + 1);
  const int result = !ms ? uv_timer_stop(uv_timer) : uv_timer_start(uv_timer, timer_cb, ms, repeat_ms);
  if (result != 0) {
    *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = result};
    return -1;
  }
  return 0;
}

// async (internal only)
struct us_internal_async *us_internal_create_async(struct us_loop_t *loop,
    void (*callback)(struct us_loop_t *), struct us_poll_error_t *failure) {
  *failure = (struct us_poll_error_t){0};
  struct us_internal_callback_t *cb = us_calloc(
      1, sizeof(struct us_internal_callback_t) + sizeof(uv_async_t));
  if (!cb) {
    *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = UV_ENOMEM};
    return NULL;
  }

  cb->loop = loop;
  cb->cb = callback;
  uv_async_t *uv_async = (uv_async_t *)(cb + 1);
  const int result = uv_async_init(loop->uv_loop, uv_async, async_cb);
  if (result != 0) {
    *failure = (struct us_poll_error_t){.domain = US_POLL_ERROR_LIBUV, .code = result};
    us_free(cb);
    return NULL;
  }
  uv_async->data = cb;
  uv_unref((uv_handle_t *)uv_async);
  return (struct us_internal_async *)cb;
}

void us_internal_async_close(struct us_internal_async *a) {
  struct us_internal_callback_t *cb = (struct us_internal_callback_t *)a;

  uv_async_t *uv_async = (uv_async_t *)(cb + 1);

  // always ref the async before closing it
  uv_ref((uv_handle_t *)uv_async);

  uv_async->data = cb;
  uv_close((uv_handle_t *)uv_async, close_cb_free);
}

void us_internal_async_wakeup(struct us_internal_async *a) {
  struct us_internal_callback_t *internal_cb =
      (struct us_internal_callback_t *)a;

  uv_async_t *uv_async = (uv_async_t *)(internal_cb + 1);
  uv_async_send(uv_async);
}

int us_socket_get_error(struct us_socket_t *s) {
  int error = 0;
  socklen_t len = sizeof(error);
  if (getsockopt(us_poll_fd((struct us_poll_t *)s), SOL_SOCKET, SO_ERROR,
                 (char *)&error, &len) == -1) {
    return errno;
  }
  return error;
}

#endif
