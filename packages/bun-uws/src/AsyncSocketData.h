#pragma once
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

#ifndef UWS_ASYNCSOCKETDATA_H
#define UWS_ASYNCSOCKETDATA_H

#include "ByteBuffer.h"

namespace uWS {

struct BackPressure {
private:
    ByteBuffer buffer;
    size_t pendingRemoval = 0;
public:
    BackPressure(BackPressure &&other) noexcept
        : buffer(std::move(other.buffer)), pendingRemoval(std::exchange(other.pendingRemoval, 0)) {}
    BackPressure() = default;

    void adopt(ByteBuffer &&owned) {
        buffer = std::move(owned);
        pendingRemoval = 0;
    }

    [[nodiscard]] bool tryAppend(const char *data, size_t length) {
        return buffer.tryAppend({length ? std::string_view(data, length) : std::string_view()});
    }
    [[nodiscard]] bool tryAppendParts(std::string_view prefix, std::initializer_list<std::string_view> parts) {
        return buffer.tryAppend(prefix, parts);
    }
    void appendAssumeCapacity(const char *data, size_t length) {
        buffer.appendAssumeCapacity(length ? std::string_view(data, length) : std::string_view());
    }
    void erase(size_t length) {
        assert(length <= this->length());
        pendingRemoval += length;
        if (pendingRemoval > (buffer.size() >> 5)) {
            buffer.discardPrefix(pendingRemoval);
            pendingRemoval = 0;
        }
    }
    size_t length() const {
        return buffer.size() - pendingRemoval;
    }
    void clear() {
        pendingRemoval = 0;
        buffer.clear();
    }
    [[nodiscard]] bool tryReserve(size_t length) {
        if (length > static_cast<size_t>(std::numeric_limits<ptrdiff_t>::max()) - pendingRemoval) return false;
        return buffer.tryReserve(length + pendingRemoval);
    }
    [[nodiscard]] bool tryResizeUninitialized(size_t length) {
        if (length > static_cast<size_t>(std::numeric_limits<ptrdiff_t>::max()) - pendingRemoval) return false;
        return buffer.tryResizeUninitialized(length + pendingRemoval);
    }
    const char *data() const {
        return buffer.empty() ? nullptr : buffer.data() + pendingRemoval;
    }
    size_t size() const {
        return length();
    }
    std::string_view view() const {
        return length() ? std::string_view(data(), length()) : std::string_view();
    }
};

/* Depending on how we want AsyncSocket to function, this will need to change */

template <bool SSL>
struct AsyncSocketData {
    /* This will do for now */
    BackPressure buffer;

    /* Allow move constructing us */
    AsyncSocketData(BackPressure &&backpressure) : buffer(std::move(backpressure)) {

    }

    /* Or empty */
    AsyncSocketData() = default;
    bool isIdle = false;
    bool isAuthorized = false; // per-socket TLS authorization status
};

}

#endif // UWS_ASYNCSOCKETDATA_H
