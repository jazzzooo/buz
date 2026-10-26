#pragma once

#include <cstdint>
#include <utility>
#include <wtf/Assertions.h>
#include <wtf/Vector.h>

namespace Bun::Bindgen {

class SharedCloneResource final {
public:
    using Release = void (*)(void*) noexcept;

    SharedCloneResource(uint8_t tag, void* value, Release release)
        : m_tag(tag)
        , m_value(value)
        , m_release(release)
    {
        RELEASE_ASSERT(value && release);
    }

    SharedCloneResource(const SharedCloneResource&) = delete;
    SharedCloneResource& operator=(const SharedCloneResource&) = delete;

    SharedCloneResource(SharedCloneResource&& other) noexcept
        : m_tag(other.m_tag)
        , m_value(std::exchange(other.m_value, nullptr))
        , m_release(other.m_release)
    {
    }

    SharedCloneResource& operator=(SharedCloneResource&& other) noexcept
    {
        if (this == &other)
            return *this;
        reset();
        m_tag = other.m_tag;
        m_value = std::exchange(other.m_value, nullptr);
        m_release = other.m_release;
        return *this;
    }

    ~SharedCloneResource() { reset(); }

    void* get(uint8_t tag) const { return tag == m_tag ? m_value : nullptr; }

private:
    void reset()
    {
        if (auto* value = std::exchange(m_value, nullptr))
            m_release(value);
    }

    uint8_t m_tag;
    void* m_value;
    Release m_release;
};

using SharedCloneResources = WTF::Vector<SharedCloneResource>;

}
