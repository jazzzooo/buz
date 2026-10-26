#include "root.h"
#include "ANSIHelpers.h"
#include "SchemaBindings.h"

#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace Bun {
using namespace WTF;

template<typename Char>
static std::optional<WTF::String> stripANSI(const std::span<const Char> input)
{
    if (input.empty()) {
        // Signal that the original string should be used
        return std::nullopt;
    }

    auto start = input.data();
    const auto end = start + input.size();

    // Lazy flat-buffer allocation: don't touch the buffer until we find an
    // escape. For no-escape input we return std::nullopt and the caller
    // reuses the original JSString with zero copies.
    Vector<Char> buffer;
    Char* cursor = nullptr;
    bool foundANSI = false;

    while (start != end) {
        const auto* escPos = ANSI::findEscapeCharacter(start, end);
        if (!escPos) {
            // No more escapes.
            if (!foundANSI)
                return std::nullopt;
            // Copy the rest of the string.
            const auto remaining = static_cast<size_t>(end - start);
            memcpy(cursor, start, remaining * sizeof(Char));
            cursor += remaining;
            break;
        }

        // Lazily allocate the worst-case buffer on first ESC candidate. Guard
        // on `cursor == nullptr` (not `!foundANSI`) so a broad-mask false
        // positive that allocates the buffer doesn't reset the cursor on the
        // next iteration when a real escape is finally found.
        // POD types skip per-element initialization in Vector::grow.
        if (cursor == nullptr) {
            buffer.grow(input.size());
            cursor = buffer.begin();
        }

        // Copy everything before the escape sequence.
        if (escPos > start) {
            const auto chunkLen = static_cast<size_t>(escPos - start);
            memcpy(cursor, start, chunkLen * sizeof(Char));
            cursor += chunkLen;
        }

        const auto* newPos = ANSI::consumeANSI(escPos, end);
        if (newPos == escPos) {
            // Broad-mask false positive — copy the byte literally.
            *cursor++ = *escPos;
            start = escPos + 1;
            continue;
        }

        ASSERT(newPos > start);
        ASSERT(newPos <= end);
        foundANSI = true;
        start = newPos;
    }

    const size_t reserved = buffer.size();
    const size_t outputLen = static_cast<size_t>(cursor - buffer.begin());
    const size_t waste = reserved - outputLen;
    buffer.shrink(outputLen);

    // Free the slack only if we wasted significantly: capacity > 2 * length OR
    // waste > 1 KB. shrinkToFit() reallocates, so for small over-allocations
    // the realloc cost outweighs the memory saved.
    if (reserved > 2 * outputLen || waste * sizeof(Char) > 1024) {
        buffer.shrinkToFit();
    }

    return String::adopt(std::move(buffer));
}

Bindgen::Engine::BunBindgenEngine_StringWidth_ansiIteratorNext_Return Bindgen::Engine::bunBindgenEngine_StringWidth_ansiIteratorNext(
    const BunBindgenEngine_StringWidth_ansiIteratorNext_Arguments& args)
{
    using Return = BunBindgenEngine_StringWidth_ansiIteratorNext_Return;
    using Slice = Return::value_type;
    RELEASE_ASSERT(args.cursor <= args.input.size());
    if (args.cursor == args.input.size())
        return std::nullopt;
    auto start = args.input.data() + args.cursor;
    const auto end = args.input.data() + args.input.size();

    // Skip past any ANSI sequences at current position
    while (start < end) {
        const auto escPos = ANSI::findEscapeCharacter(start, end);
        if (escPos != start) break;
        const auto after = ANSI::consumeANSI(start, end);
        if (after == start) {
            start++;
            break;
        }
        start = after;
    }

    if (start >= end) {
        return std::nullopt;
    }

    const auto escPos = ANSI::findEscapeCharacter(start, end);
    const auto slice_end = escPos ? escPos : end;
    return Slice {
        .start = static_cast<size_t>(start - args.input.data()),
        .length = static_cast<size_t>(slice_end - start),
        .cursor = static_cast<size_t>(slice_end - args.input.data()),
    };
}

WTF::String Bindgen::Cpp::bunBindgenCpp_BunObject_stripANSI(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_stripANSI_Arguments& args)
{
    const auto& input = args.input;
    if (input.isEmpty())
        return input;

    std::optional<WTF::String> result;
    if (input.is8Bit())
        result = stripANSI<Latin1Character>(input.span8());
    else
        result = stripANSI<UChar>(input.span16());

    return result.value_or(input);
}
}
