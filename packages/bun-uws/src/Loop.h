#pragma once
/*
 * Authored by Alex Hultman, 2018-2020.
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

#ifndef UWS_LOOP_H
#define UWS_LOOP_H

/* The loop is lazily created per-thread and run with run() */

#include "LoopData.h"
#include <libusockets.h>
#include <atomic>
#include <iostream>
#include "AsyncSocket.h"

namespace uWS {
struct Loop {
private:
    static void wakeupCb(us_loop_t *loop) {
        LoopData *loopData = (LoopData *) us_loop_ext(loop);

        /* Swap current deferQueue */
        loopData->deferMutex.lock();
        int oldDeferQueue = loopData->currentDeferQueue;
        loopData->currentDeferQueue = (loopData->currentDeferQueue + 1) % 2;
        loopData->deferMutex.unlock();

        /* Drain the queue */
        for (auto &x : loopData->deferQueues[oldDeferQueue]) {
            x();
        }
        loopData->deferQueues[oldDeferQueue].clear();
    }

    static void preCb(us_loop_t *loop) {
        LoopData *loopData = (LoopData *) us_loop_ext(loop);

        loopData->runHooks();


        drainCorkedSockets(loop);
    }

    static void postCb(us_loop_t *loop) {
        LoopData *loopData = (LoopData *) us_loop_ext(loop);

        loopData->runHooks();

    }

    Loop() = delete;
    ~Loop() = default;

    Loop *init() {
        new (us_loop_ext((us_loop_t *) this)) LoopData;
        return this;
    }

    static Loop *create(void *hint, us_poll_error_t *failure) {
        Loop *loop = (Loop *) us_create_loop(hint, wakeupCb, preCb, postCb, sizeof(LoopData), failure);
        return loop ? loop->init() : nullptr;
    }

    /* What to do with loops created with existingNativeLoop? */
    struct LoopCleaner {
        ~LoopCleaner() {
            // There's no need to call this destructor if Bun is in the process of exiting.
            // This is both a performance thing, and also to prevent freeing some things which are not meant to be freed
            // such as uv_tty_t
            if(loop && cleanMe && !processIsExiting.load(std::memory_order_relaxed)) {
                cleanMe = false;
                loop->free();
            }
        }
        Loop *loop = nullptr;
        bool cleanMe = false;
    };

    static inline std::atomic_bool processIsExiting = false;

    static LoopCleaner &getLazyLoop() {
        static thread_local LoopCleaner lazyLoop;
        return lazyLoop;
    }

public:
    static void drainCorkedSockets(us_loop_t *loop) {
        auto *loopData = static_cast<LoopData *>(us_loop_ext(loop));
        for (int i = 0; i < 2; i++) {
            bool ssl;
            void *socket = loopData->getAnyCorkedSocket(&ssl);
            if (!socket) break;
            const auto result = ssl ? static_cast<AsyncSocket<true> *>(socket)->uncork()
                                    : static_cast<AsyncSocket<false> *>(socket)->uncork();
            if (result.status == WriteStatus::OutOfMemory) {
                if (ssl) static_cast<AsyncSocket<true> *>(socket)->closeOnOutOfMemory();
                else static_cast<AsyncSocket<false> *>(socket)->closeOnOutOfMemory();
            }
        }
    }

    static void markProcessExiting() {
        processIsExiting.store(true, std::memory_order_relaxed);
    }

    static Loop *ensure(void *existingNativeLoop, us_poll_error_t *failure) {
        *failure = {};
        auto &owner = getLazyLoop();
        if (!owner.loop) {
            Loop *loop = create(existingNativeLoop, failure);
            if (!loop) return nullptr;
            owner.loop = loop;
            owner.cleanMe = existingNativeLoop == nullptr;
        }
        return owner.loop;
    }

    static Loop *get() {
        Loop *loop = getLazyLoop().loop;
        RELEASE_ASSERT(loop);
        return loop;
    }

    static void clearLoopAtThreadExit() {
        if (getLazyLoop().loop && getLazyLoop().cleanMe) {
            getLazyLoop().loop->free();
        }
    }

    /* Freeing the default loop should be done once */
    void free() {
        LoopData *loopData = (LoopData *) us_loop_ext((us_loop_t *) this);
        
        loopData->~LoopData();
        /* uSockets will track whether this loop is owned by us or a borrowed alien loop */
        us_loop_free((us_loop_t *) this);

        /* Reset lazyLoop */
        getLazyLoop().loop = nullptr;
        getLazyLoop().cleanMe = false;
    }

    static LoopData* data(struct us_loop_t *loop) {
        return (LoopData *) us_loop_ext(loop);
    }

    void addHook(LoopData::Hook &hook) {
        auto *data = Loop::data(reinterpret_cast<us_loop_t *>(this));
        assert(!hook.previous);
        hook.next = data->hooks;
        hook.previous = &data->hooks;
        if (hook.next) hook.next->previous = &hook.next;
        data->hooks = &hook;
    }

    void removeHook(LoopData::Hook &hook) {
        if (!hook.previous) return;
        auto *data = Loop::data(reinterpret_cast<us_loop_t *>(this));
        for (auto *iteration = data->hookIteration; iteration; iteration = iteration->parent) {
            if (iteration->cursor == &hook) iteration->cursor = hook.next;
        }
        *hook.previous = hook.next;
        if (hook.next) hook.next->previous = hook.previous;
        hook.next = nullptr;
        hook.previous = nullptr;
    }

    /* Defer this callback on Loop's thread of execution */
    void defer(MoveOnlyFunction<void()> &&cb) {
        LoopData *loopData = (LoopData *) us_loop_ext((us_loop_t *) this);

        //if (std::thread::get_id() == ) // todo: add fast path for same thread id
        loopData->deferMutex.lock();
        loopData->deferQueues[loopData->currentDeferQueue].emplace_back(std::move(cb));
        loopData->deferMutex.unlock();

        us_wakeup_loop((us_loop_t *) this);
    }

    /* Actively block and run this loop */
    void run() {
        us_loop_run((us_loop_t *) this);
    }

    /* Dynamically change this */
    void setSilent(bool silent) {
        ((LoopData *) us_loop_ext((us_loop_t *) this))->noMark = silent;
    }
};

/* Can be called from any thread to run the thread local loop */
inline void run() {
    Loop::get()->run();
}

}

#endif // UWS_LOOP_H
