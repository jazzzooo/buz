#pragma once

#include "BindingRuntimeDeclarations.h"
#include <memory>
#include <utility>
#include <variant>

namespace Bun::Bindgen {

void raiseBindingOutOfMemory(EngineCallContext&);

template<typename Codec>
class CppErrorSink final {
public:
    using Errors = typename Codec::Errors;
    explicit CppErrorSink(EngineCallContext& context)
        : m_context(context)
    {
    }
    template<typename Failure>
    void fail(Failure failure) { Codec::raise(m_context, WTF::move(failure)); }
    void outOfMemory() { raiseBindingOutOfMemory(m_context); }

private:
    EngineCallContext& m_context;
};

namespace Detail {
template<typename Codec> class CppCompletionEntry;
}

template<typename Codec>
class CppCompletion final {
public:
    using Value = typename Codec::Value;
    using Errors = typename Codec::Errors;

    CppCompletion(const CppCompletion&) = delete;
    CppCompletion& operator=(const CppCompletion&) = delete;
    CppCompletion(CppCompletion&&) noexcept = default;
    CppCompletion& operator=(CppCompletion&&) noexcept = default;

    CppCompletion take() { return CppCompletion(consume()); }
    CppCompletion clone() const
    {
        RELEASE_ASSERT(m_handle);
        Codec::clone(m_handle.get());
        return CppCompletion(m_handle.get());
    }
    void resolve(Value value) { Codec::resolve(consume(), WTF::move(value)); }
    template<typename Failure>
    void fail(Failure failure) { Codec::fail(consume(), WTF::move(failure)); }
    void outOfMemory() { Codec::outOfMemory(consume()); }

private:
    using Handle = typename Codec::Handle;
    explicit CppCompletion(Handle* handle)
        : m_handle(handle)
    {
    }
    Handle* consume()
    {
        RELEASE_ASSERT(m_handle);
        return m_handle.release();
    }
    void reset() { m_handle.reset(); }

    struct Release {
        void operator()(Handle* handle) const { Codec::release(handle); }
    };
    std::unique_ptr<Handle, Release> m_handle;
    friend class Detail::CppCompletionEntry<Codec>;
};

namespace Detail {
template<typename Codec>
class CppCompletionEntry final {
public:
    using Handle = typename Codec::Handle;
    explicit CppCompletionEntry(Handle* handle)
        : m_handle(handle)
        , m_sender(handle)
    {
    }
    CppCompletionEntry(const CppCompletionEntry&) = delete;
    CppCompletionEntry& operator=(const CppCompletionEntry&) = delete;
    ~CppCompletionEntry()
    {
        m_sender.reset();
        Codec::finish(m_handle, m_succeeded);
    }
    CppCompletion<Codec>& sender() { return m_sender; }
    void commit() { m_succeeded = true; }

private:
    Handle* m_handle;
    CppCompletion<Codec> m_sender;
    bool m_succeeded { false };
};
}
}
