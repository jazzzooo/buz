#pragma once

#include "root.h"
#include <wtf/Vector.h>
#include <wtf/text/ASCIIFastPath.h>
#include <wtf/text/StringView.h>

namespace JSC {
class VM;
}

namespace Bun {
String base64URLEncodeToString(const Vector<uint8_t>& data);
String toISOString(JSC::VM& vm, double date);

class PreparedTimeZoneOverride {
public:
    enum class Result : uint8_t { Valid, Invalid, OutOfMemory };

    PreparedTimeZoneOverride() = default;
    PreparedTimeZoneOverride(const PreparedTimeZoneOverride&) = delete;
    PreparedTimeZoneOverride& operator=(const PreparedTimeZoneOverride&) = delete;

    Result prepare(WTF::StringView);
    void commit();
    std::span<const char16_t> identifier() const
    {
        RELEASE_ASSERT(m_prepared);
        return m_identifier.span();
    }

private:
    WTF::Vector<char16_t> m_identifier;
    bool m_prepared { false };
};
}
