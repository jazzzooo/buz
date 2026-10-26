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
// clang-format off
#ifndef UWS_ASYNCSOCKET_H
#define UWS_ASYNCSOCKET_H

/* This class implements async socket memory management strategies */

/* NOTE: Many unsigned/signed conversion warnings could be solved by moving from int length
 * to unsigned length for everything to/from uSockets - this would however remove the opportunity
 * to signal error with -1 (which is how the entire UNIX syscalling is built). */

#include <cstring>
#include <iostream>
#include <optional>

#include "libusockets.h"
#include "bun-usockets/src/internal/internal.h"



#include "LoopData.h"
#include "AsyncSocketData.h"

namespace uWS {

    enum class WriteStatus { Complete, Backpressure, OutOfMemory, Closed };
    struct WriteResult {
        int written;
        WriteStatus status;
    };

    enum SendBufferAttribute {
        NEEDS_NOTHING,
        NEEDS_DRAIN
    };

    template <bool, bool, typename> struct WebSocketContext;

template <bool SSL>
struct AsyncSocket {
    /* This guy is promiscuous */
    template <bool> friend struct HttpContext;
    template <bool, bool, typename> friend struct WebSocketContext;
    template <bool> friend struct TemplatedApp;
    template <bool, typename> friend struct WebSocketContextData;
    template <typename, typename> friend struct TopicTree;
    template <bool> friend struct HttpResponse;


public:
    /* Returns SSL pointer or FD as pointer */
    void *getNativeHandle() {
        return us_socket_get_native_handle((us_socket_t *) this);
    }

    /* Get loop data for socket */
    LoopData *getLoopData() {
        return (LoopData *) us_loop_ext(us_socket_group_loop(us_socket_group((us_socket_t *) this)));
    }

    /* Get socket extension */
    AsyncSocketData<SSL> *getAsyncSocketData() {
        return (AsyncSocketData<SSL> *) us_socket_ext((us_socket_t *) this);
    }

    /* Socket timeout */
    void timeout(unsigned int seconds) {
        us_socket_timeout((us_socket_t *) this, seconds);
    }

    /* Shutdown socket without any automatic drainage */
    void shutdown() {
        us_socket_shutdown((us_socket_t *) this);
    }

    /* Experimental pause */
    us_socket_t *pause() {
        us_socket_pause((us_socket_t *) this);
        return (us_socket_t *) this;
    }

    /* Experimental resume */
    us_socket_t *resume() {
        us_socket_resume((us_socket_t *) this);
        return (us_socket_t *) this;
    }

    /* Immediately close socket */
    us_socket_t *close() {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return reinterpret_cast<us_socket_t *>(this);
        this->uncorkWithoutSending();
        return us_socket_close((us_socket_t *) this, 0, nullptr);
    }

    us_socket_t *closeOnOutOfMemory() {
        static constexpr char reason[] = "Out of memory while buffering socket output";
        return us_socket_close((us_socket_t *) this, sizeof(reason) - 1, const_cast<char *>(reason));
    }

    void uncorkWithoutSending() {
        /* Called from close/destroy paths. Removes this socket from any cork
         * slot to prevent the drain loop from dereferencing a freed pointer. */
        getLoopData()->unborrowCorkSlot(this);
    }

    /* Cork this socket. Two sockets may be corked per-loop at once. */
    void cork() {
        LoopData *loopData = getLoopData();

        /* Already corked? Nothing to do. */
        if (loopData->findCorkSlot(this) != LoopData::INVALID_CORK_SLOT) {
            return;
        }

        /* Grab a free slot. */
        if (loopData->acquireCorkSlot(this, SSL) != LoopData::INVALID_CORK_SLOT) {
            return;
        }

        /* Both slots hold data from other sockets. Force-uncork the least
         * recently used one to make room. */
        int victimSlot = loopData->getLRUCorkSlot();
        auto *vs = loopData->getCorkSlot(victimSlot);
        void *victim = vs->socket;
        bool victimSsl = vs->ssl;
        const auto result = victimSsl ? ((AsyncSocket<true> *) victim)->uncork() : ((AsyncSocket<false> *) victim)->uncork();
        if (result.status == WriteStatus::OutOfMemory || us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return;
        loopData->acquireCorkSlot(this, SSL);
    }

    /* Returns whether we are corked */
    bool isCorked() {
        return getLoopData()->findCorkSlot(this) != LoopData::INVALID_CORK_SLOT;
    }

    bool hasPendingOutput() {
        if (getAsyncSocketData()->buffer.length()) return true;
        auto *loop = getLoopData();
        const int slot = loop->findCorkSlot(this);
        return slot != LoopData::INVALID_CORK_SLOT && loop->getCorkSlot(slot)->offset != 0;
    }

    /* Returns a suitable buffer for temporary assemblation of send data */
    std::optional<std::pair<char *, SendBufferAttribute>> getSendBuffer(size_t size) {
        LoopData *loopData = getLoopData();
        BackPressure &backPressure = getAsyncSocketData()->buffer;
        size_t existingBackpressure = backPressure.length();

        int slot = loopData->findCorkSlot(this);
        bool corked = slot != LoopData::INVALID_CORK_SLOT;
        unsigned int currentOffset = corked ? loopData->getCorkSlot(slot)->offset : 0;

        if ((!existingBackpressure) && corked && (size <= LoopData::CORK_BUFFER_SIZE - currentOffset)) {
            auto *s = loopData->getCorkSlot(slot);
            char *sendBuffer = s->buffer + s->offset;
            s->offset += (unsigned int) size;
            ASSERT(s->offset <= LoopData::CORK_BUFFER_SIZE);
            loopData->touchCorkSlot(slot);
            return std::pair {sendBuffer, SendBufferAttribute::NEEDS_NOTHING};
        } else {
            /* Fallback: move any corked data into the backpressure buffer. */
            unsigned int ourCorkOffset = 0;
            char *ourCorkBuffer = nullptr;
            if (corked) {
                auto *s = loopData->getCorkSlot(slot);
                ourCorkOffset = s->offset;
                ourCorkBuffer = s->buffer;
            }

            constexpr auto maximum = static_cast<size_t>(std::numeric_limits<ptrdiff_t>::max());
            if (size > maximum - existingBackpressure || ourCorkOffset > maximum - existingBackpressure - size) return std::nullopt;
            if (!backPressure.tryResizeUninitialized(ourCorkOffset + existingBackpressure + size)) return std::nullopt;

            if (ourCorkOffset > 0) {
                memcpy((char *) backPressure.data() + existingBackpressure, ourCorkBuffer, ourCorkOffset);
                loopData->getCorkSlot(slot)->offset = 0;
            }
            return std::pair {(char *) backPressure.data() + ourCorkOffset + existingBackpressure, SendBufferAttribute::NEEDS_DRAIN};
        }
    }

    /* Returns the user space backpressure. */
    size_t getBufferedAmount() {
        return getAsyncSocketData()->buffer.length();
    }

    /* Returns the text representation of an IPv4 or IPv6 address */
    std::string_view addressAsText(std::string_view binary) {
        static thread_local char buf[64];
        int ipLength = 0;

        if (!binary.length()) {
            return {};
        }

        unsigned char *b = (unsigned char *) binary.data();

        if (binary.length() == 4) {
            ipLength = snprintf(buf, sizeof(buf), "%u.%u.%u.%u", b[0], b[1], b[2], b[3]);
        } else {
            ipLength = snprintf(buf, sizeof(buf), "%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x",
                b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11],
                b[12], b[13], b[14], b[15]);
        }

        return {buf, (unsigned int) ipLength};
    }

    /* Returns the remote IP address or empty string on failure */
    std::string_view getRemoteAddress() {
        static thread_local char buf[16];
        int ipLength = 16;
        us_socket_remote_address((us_socket_t *) this, buf, &ipLength);
        return std::string_view(buf, (unsigned int) ipLength);
    }

    /* Returns the text representation of IP */
    std::string_view getRemoteAddressAsText() {
        return addressAsText(getRemoteAddress());
    }

private:
    WriteResult writeToSocket(const char *data, int length) {
        const auto result = us_socket_write_checked(reinterpret_cast<us_socket_t *>(this), data, length);
        switch (result.status) {
        case US_SOCKET_WRITE_COMPLETE: return {result.written, WriteStatus::Complete};
        case US_SOCKET_WRITE_BACKPRESSURE: return {result.written, WriteStatus::Backpressure};
        case US_SOCKET_WRITE_CLOSED: return {0, WriteStatus::Closed};
        case US_SOCKET_WRITE_FAILED:
            // SSL and native write frames have unwound before close callbacks can destroy socket state.
            close();
            return {0, WriteStatus::Closed};
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

public:
    [[nodiscard]] WriteStatus flush() {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        auto &buffer = getAsyncSocketData()->buffer;
        while (buffer.length()) {
            const auto length = static_cast<int>(std::min(buffer.length(), static_cast<size_t>(INT_MAX)));
            const auto result = writeToSocket(buffer.data(), length);
            if (result.status == WriteStatus::Closed) return WriteStatus::Closed;
            buffer.erase(static_cast<unsigned int>(result.written));
            if (result.status == WriteStatus::Backpressure) return WriteStatus::Backpressure;
        }
        return WriteStatus::Complete;
    }

    [[nodiscard]] WriteStatus writeParts(std::initializer_list<std::string_view> parts) {
        if (us_socket_is_closed(reinterpret_cast<us_socket_t *>(this))) return WriteStatus::Closed;
        constexpr auto maximum = static_cast<size_t>(std::numeric_limits<ptrdiff_t>::max());
        size_t length = 0;
        for (auto part : parts) {
            if (part.size() > maximum - length) return WriteStatus::OutOfMemory;
            length += part.size();
        }
        if (!length) return WriteStatus::Complete;
        auto *loop = getLoopData();
        auto &buffer = getAsyncSocketData()->buffer;
        const int slot = loop->findCorkSlot(this);
        const auto cork = slot == LoopData::INVALID_CORK_SLOT ? nullptr : loop->getCorkSlot(slot);
        if (cork && !buffer.length() && length <= LoopData::CORK_BUFFER_SIZE - cork->offset) {
            for (auto part : parts) {
                if (part.empty()) continue;
                memcpy(cork->buffer + cork->offset, part.data(), part.size());
                cork->offset += static_cast<unsigned int>(part.size());
            }
            loop->touchCorkSlot(slot);
            return WriteStatus::Complete;
        }
        const auto prefix = cork ? std::string_view(cork->buffer, cork->offset) : std::string_view();
        if (!buffer.tryAppendParts(prefix, parts)) return WriteStatus::OutOfMemory;
        if (cork) cork->offset = 0;
        return flush();
    }

    [[nodiscard]] WriteResult write(const char *src, int length, bool optionally = false, bool skipCork = false) {
        ASSERT(length >= 0);
        if (us_socket_is_closed((us_socket_t *) this)) {
            return {0, WriteStatus::Closed};
        }

        LoopData *loopData = getLoopData();
        AsyncSocketData<SSL> *asyncSocketData = getAsyncSocketData();
        /* We are limited if we have a per-socket buffer */
        if (asyncSocketData->buffer.length()) {
            size_t buffer_len = asyncSocketData->buffer.length();
            // we cannot not flush more than INT_MAX bytes at a time
            int max_flush_len = std::min(buffer_len, (size_t)INT_MAX);

            /* Write off as much as we can */
            const auto result = writeToSocket(asyncSocketData->buffer.data(), max_flush_len);
            if (result.status == WriteStatus::Closed) return {0, WriteStatus::Closed};
            const int written = result.written;
            /* On failure return, otherwise continue down the function */
            if ((unsigned int) written < buffer_len) {
                /* Update buffering (todo: we can do better here if we keep track of what happens to this guy later on) */
                asyncSocketData->buffer.erase((unsigned int) written);

                if (optionally) {
                    /* Thankfully we can exit early here */
                    return {0, WriteStatus::Backpressure};
                } else {
                    if (!asyncSocketData->buffer.tryAppend(src, static_cast<size_t>(length))) return {0, WriteStatus::OutOfMemory};
                    return {length, WriteStatus::Backpressure};
                }
            }

            /* At this point we simply have no buffer and can continue as normal */
            asyncSocketData->buffer.clear();
        }

        if (length) {
            int slot = skipCork ? LoopData::INVALID_CORK_SLOT : loopData->findCorkSlot(this);
            if (slot != LoopData::INVALID_CORK_SLOT) {
                /* We are corked */
                auto *s = loopData->getCorkSlot(slot);
                if (LoopData::CORK_BUFFER_SIZE - s->offset >= (unsigned int) length) {
                    /* If the entire chunk fits in cork buffer */
                    memcpy(s->buffer + s->offset, src, (unsigned int) length);
                    s->offset += (unsigned int) length;
                    ASSERT(s->offset <= LoopData::CORK_BUFFER_SIZE);
                    loopData->touchCorkSlot(slot);
                    /* Fall through to default return */
                } else {
                    /* Chunk doesn't fit; flush cork + write the rest. */
                    return uncork(src, length, optionally);
                }
            } else {
                /* We are not corked */
                const auto result = writeToSocket(src, length);
                if (result.status == WriteStatus::Closed) return {0, WriteStatus::Closed};
                const int written = result.written;

                /* Did we fail? */
                if (written < length) {
                    /* If the write was optional then just bail out */
                    if (optionally) {
                        return {written, WriteStatus::Backpressure};
                    }
                    if (!asyncSocketData->buffer.tryAppend(src + written, static_cast<size_t>(length - written))) return {written, WriteStatus::OutOfMemory};
                    return {length, WriteStatus::Backpressure};
                }
                /* Fall through to default return */
            }
        }

        /* Default fall through return */
        return {length, WriteStatus::Complete};
    }

    [[nodiscard]] WriteResult uncork(const char *src = nullptr, int length = 0, bool optionally = false) {
        if (us_socket_is_closed((us_socket_t *) this)) return {0, WriteStatus::Closed};
        LoopData *loopData = getLoopData();

        int slot = loopData->findCorkSlot(this);
        if (slot == LoopData::INVALID_CORK_SLOT) {
            return write(src, length, optionally);
        }

        auto *s = loopData->getCorkSlot(slot);
        unsigned int offset = s->offset;
        char *buffer = s->buffer;
        if (offset) {
            auto result = write(buffer, static_cast<int>(offset), false, true);
            if (result.status == WriteStatus::OutOfMemory) {
                const auto remaining = offset - static_cast<unsigned int>(result.written);
                if (result.written) memmove(buffer, buffer + result.written, remaining);
                s->offset = remaining;
                return {0, WriteStatus::OutOfMemory};
            }
            if (result.status == WriteStatus::Closed) return {0, WriteStatus::Closed};
            loopData->releaseCorkSlot(slot);
            if (result.status == WriteStatus::Backpressure && optionally) return {0, WriteStatus::Backpressure};
            if (length == 0) return {0, result.status};
        } else {
            loopData->releaseCorkSlot(slot);
        }

        return write(src, length, optionally);
    }
};

}

#endif // UWS_ASYNCSOCKET_H
