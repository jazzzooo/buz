#pragma once

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <string_view>
#include <utility>

namespace uWS {

class ByteBuffer {
    char *bytes = nullptr;
    size_t used = 0;
    size_t allocated = 0;

public:
    ByteBuffer() = default;
    ByteBuffer(const ByteBuffer &) = delete;
    ByteBuffer &operator=(const ByteBuffer &) = delete;

    ByteBuffer(ByteBuffer &&other) noexcept
        : bytes(std::exchange(other.bytes, nullptr)),
          used(std::exchange(other.used, 0)),
          allocated(std::exchange(other.allocated, 0)) {}

    ByteBuffer &operator=(ByteBuffer &&other) noexcept {
        if (this != &other) {
            free(bytes);
            bytes = std::exchange(other.bytes, nullptr);
            used = std::exchange(other.used, 0);
            allocated = std::exchange(other.allocated, 0);
        }
        return *this;
    }

    ~ByteBuffer() { free(bytes); }

    char *data() { return bytes; }
    const char *data() const { return bytes; }
    size_t size() const { return used; }
    bool empty() const { return used == 0; }
    std::string_view view() const { return used ? std::string_view(bytes, used) : std::string_view(); }

    void clear() {
        free(bytes);
        bytes = nullptr;
        used = 0;
        allocated = 0;
    }

    void discardPrefix(size_t length) {
        assert(length <= used);
        if (length == used) {
            clear();
            return;
        }
        if (length) memmove(bytes, bytes + length, used - length);
        used -= length;
    }

    [[nodiscard]] bool tryResizeUninitialized(size_t length) {
        if (!tryReserve(length)) return false;
        used = length;
        return true;
    }

    [[nodiscard]] bool tryReserve(size_t required) {
        constexpr auto maximum = static_cast<size_t>(std::numeric_limits<ptrdiff_t>::max());
        if (required > maximum) return false;
        if (required <= allocated) return true;
        const size_t growth = std::min(std::max(allocated / 2, size_t(256)), maximum - allocated);
        const size_t capacity = std::max(required, allocated + growth);
        auto *replacement = static_cast<char *>(realloc(bytes, capacity));
        if (!replacement) return false;
        bytes = replacement;
        allocated = capacity;
        return true;
    }

    [[nodiscard]] bool tryAppend(std::initializer_list<std::string_view> parts) {
        return tryAppend({}, parts);
    }

    [[nodiscard]] bool tryAppend(std::string_view prefix, std::initializer_list<std::string_view> parts) {
        constexpr auto maximum = static_cast<size_t>(std::numeric_limits<ptrdiff_t>::max());
        if (prefix.size() > maximum - used) return false;
        size_t required = used + prefix.size();
        const auto bufferAddress = reinterpret_cast<uintptr_t>(bytes);
        const auto prefixAddress = reinterpret_cast<uintptr_t>(prefix.data());
        bool aliases = !prefix.empty() && prefixAddress >= bufferAddress && prefixAddress - bufferAddress < allocated;
        for (auto part : parts) {
            if (part.size() > maximum - required) return false;
            required += part.size();
            const auto address = reinterpret_cast<uintptr_t>(part.data());
            if (!part.empty() && address >= bufferAddress && address - bufferAddress < allocated) aliases = true;
        }
        ByteBuffer replacement;
        ByteBuffer *destination = this;
        if (aliases) {
            if (!replacement.tryReserve(required)) return false;
            memcpy(replacement.bytes, bytes, used);
            replacement.used = used;
            destination = &replacement;
        } else if (!tryReserve(required)) return false;
        destination->appendAssumeCapacity(prefix);
        for (auto part : parts) {
            destination->appendAssumeCapacity(part);
        }
        if (aliases) *this = std::move(replacement);
        return true;
    }

    void appendAssumeCapacity(std::string_view part) {
        assert(part.size() <= allocated - used);
        if (!part.empty()) memmove(bytes + used, part.data(), part.size());
        used += part.size();
    }
};

}
