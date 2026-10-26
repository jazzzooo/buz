#pragma once

#include "root.h"
#include "JavaScriptCore/BytecodeIndex.h"
#include "wtf/text/OrdinalNumber.h"
#include "wtf/text/WTFString.h"
#include <optional>

struct VirtualMachine;

namespace Bun {

inline std::optional<uint32_t> knownStackIndex(int32_t index)
{
    if (index < 0)
        return std::nullopt;
    return static_cast<uint32_t>(index);
}

inline int32_t stackIndexOrUnknown(const std::optional<uint32_t>& index)
{
    if (!index)
        return -1;
    RELEASE_ASSERT(*index <= static_cast<uint32_t>(INT32_MAX));
    return static_cast<int32_t>(*index);
}

struct ErrorStackFramePosition {
    int32_t lineZeroBased { -1 };
    int32_t columnZeroBased { -1 };
    int32_t bytePosition { -1 };

    WTF::OrdinalNumber line() const { return WTF::OrdinalNumber::fromZeroBasedInt(lineZeroBased); }
    WTF::OrdinalNumber column() const { return WTF::OrdinalNumber::fromZeroBasedInt(columnZeroBased); }
};

struct RemappableStackFrame {
    WTF::String sourceURL;
    ErrorStackFramePosition position;
    bool remapped { false };
};

ErrorStackFramePosition getAdjustedPositionForBytecode(JSC::CodeBlock* code, JSC::BytecodeIndex bc);
void remapStackFramePosition(::VirtualMachine*, RemappableStackFrame&);
void remapStackFramePositions(::VirtualMachine*, std::span<RemappableStackFrame>);

} // namespace Bun
