#pragma once

#include <cassert>
#include <type_traits>
#include <utility>

namespace uWS {

// The registering owner keeps the borrowed context alive until the callback is removed or finishes.
template <typename Handler>
class HttpCallback {
    static_assert(std::is_pointer_v<Handler> && std::is_function_v<std::remove_pointer_t<Handler>>);
    Handler handler = nullptr;
    void *context = nullptr;

public:
    void set(void *data, Handler function) {
        handler = function;
        context = function ? data : nullptr;
    }

    void clear() {
        handler = nullptr;
        context = nullptr;
    }

    HttpCallback take() { return std::exchange(*this, HttpCallback{}); }
    explicit operator bool() const { return handler != nullptr; }
    bool operator==(const HttpCallback &) const = default;

    template <typename... Args>
    auto operator()(Args &&...args) const {
        const auto function = handler;
        auto *data = context;
        assert(function);
        return function(std::forward<Args>(args)..., data);
    }
};

}
