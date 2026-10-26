#pragma once

#include <cassert>
#include <cstddef>
#include "libusockets.h"

namespace uWS {

struct WebSocketContextLifetime {
    WebSocketContextLifetime *next = nullptr;
    WebSocketContextLifetime **previous = nullptr;
    us_socket_group_t *group;
    void *context;
    void (*destroy)(void *);
    size_t references = 1;

    void attach(WebSocketContextLifetime *&head) {
        assert(!previous);
        next = head;
        previous = &head;
        if (next) next->previous = &this->next;
        head = this;
    }

    void ref() {
        assert(references);
        ++references;
    }

    void deref() {
        assert(references);
        if (--references) return;
        if (previous) *previous = next;
        if (next) next->previous = previous;
        destroy(context);
    }
};

}
