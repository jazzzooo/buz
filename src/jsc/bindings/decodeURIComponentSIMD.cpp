#include "root.h"

#include "decodeURIComponentSIMD.h"
#include "SchemaBindings.h"
#include "StringConversion.h"
#include <unicode/utf8.h>
#include <wtf/SIMDHelpers.h>
#include <wtf/SIMDUTF.h>
#include <wtf/text/StringBuilder.h>

namespace Bun {
using namespace WTF;

ALWAYS_INLINE static uint8_t hexToInt(uint8_t c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return 255;
}

template<typename Character>
static Expected<String, UTF8ConversionError> copyDecodedString(std::span<const Character> characters)
{
    std::span<Character> output;
    auto impl = StringImpl::tryCreateUninitialized(characters.size(), output);
    if (!impl)
        return makeUnexpected(UTF8ConversionError::OutOfMemory);
    if (!characters.empty())
        memcpy(output.data(), characters.data(), characters.size_bytes());
    return String(WTF::move(impl));
}

Expected<String, UTF8ConversionError> decodeURIComponentSIMD(std::span<const uint8_t> input)
{
    if (input.empty())
        return emptyString();

    const bool ascii = simdutf::validate_ascii(reinterpret_cast<const char*>(input.data()), input.size());
    const uint8_t* cursor = input.data();
    const uint8_t* end = cursor + input.size();
    constexpr size_t stride = SIMD::stride<uint8_t>;
    constexpr char16_t replacementChar = 0xFFFD;
    auto percentVector = SIMD::splat<uint8_t>('%');

    if (ascii) {
        for (; static_cast<size_t>(end - cursor) >= stride; cursor += stride) {
            if (SIMD::isNonZero(SIMD::equal(SIMD::load(cursor), percentVector)))
                break;
        }
        while (cursor < end && *cursor != '%')
            ++cursor;
        if (cursor == end)
            return copyDecodedString<Latin1Character>(input);
    }

    StringBuilder result(OverflowPolicy::RecordOverflow);
    const size_t prefixLength = cursor - input.data();
    if (prefixLength > StringImpl::MaxLength)
        return makeUnexpected(UTF8ConversionError::OutOfMemory);
    result.append(input.first(prefixLength));

    while (cursor < end) {
        if (result.hasOverflowed())
            return makeUnexpected(UTF8ConversionError::OutOfMemory);
        if (*cursor == '%') {
            if (end - cursor < 3) {
                result.append(replacementChar);
                ++cursor;
                continue;
            }

            auto highNibble = hexToInt(cursor[1]);
            auto lowNibble = hexToInt(cursor[2]);
            cursor += 3;
            if (highNibble > 15 || lowNibble > 15) {
                result.append(replacementChar);
                continue;
            }
            const uint8_t firstByte = (highNibble << 4) | lowNibble;
            if (firstByte < 0x80) {
                result.append(firstByte);
                continue;
            }

            unsigned remaining;
            uint32_t scalar;
            uint32_t minimum;
            if ((firstByte & 0xE0) == 0xC0) {
                remaining = 1;
                scalar = firstByte & 0x1F;
                minimum = 0x80;
            } else if ((firstByte & 0xF0) == 0xE0) {
                remaining = 2;
                scalar = firstByte & 0x0F;
                minimum = 0x800;
            } else if ((firstByte & 0xF8) == 0xF0) {
                remaining = 3;
                scalar = firstByte & 0x07;
                minimum = 0x10000;
            } else {
                result.append(replacementChar);
                continue;
            }

            // An invalid continuation belongs to the next decoding step.
            for (; remaining; --remaining) {
                if (end - cursor < 3 || *cursor != '%')
                    break;
                highNibble = hexToInt(cursor[1]);
                lowNibble = hexToInt(cursor[2]);
                if (highNibble > 15 || lowNibble > 15)
                    break;
                const uint8_t byte = (highNibble << 4) | lowNibble;
                if ((byte & 0xC0) != 0x80)
                    break;
                scalar = (scalar << 6) | (byte & 0x3F);
                cursor += 3;
            }
            if (remaining || scalar < minimum || scalar > 0x10FFFF || U_IS_SURROGATE(scalar))
                result.append(replacementChar);
            else
                result.append(static_cast<char32_t>(scalar));
        } else if (!ascii) {
            int32_t offset = 0;
            const int32_t length = static_cast<int32_t>(std::min<size_t>(end - cursor, U8_MAX_LENGTH));
            UChar32 scalar;
            U8_NEXT(cursor, offset, length, scalar);
            cursor += offset;
            result.append(scalar < 0 ? static_cast<char32_t>(replacementChar) : static_cast<char32_t>(scalar));
        } else {
            const uint8_t* start = cursor;
            while (static_cast<size_t>(end - cursor) >= stride) {
                if (SIMD::isNonZero(SIMD::equal(SIMD::load(cursor), percentVector)))
                    break;
                cursor += stride;
            }
            while (cursor < end && *cursor != '%')
                ++cursor;
            const size_t length = cursor - start;
            if (length > StringImpl::MaxLength)
                return makeUnexpected(UTF8ConversionError::OutOfMemory);
            result.append(std::span<const Latin1Character>(start, length));
        }
    }

    if (result.hasOverflowed())
        return makeUnexpected(UTF8ConversionError::OutOfMemory);
    if (result.is8Bit())
        return copyDecodedString(result.span8());
    return copyDecodedString(result.span16());
}

std::optional<WTF::String> Bindgen::Cpp::bunBindgenCpp_bindgen_test_decodeURIComponentSIMD(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_bindgen_test_decodeURIComponentSIMD_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    const auto decode = [&](std::span<const uint8_t> bytes) -> std::optional<WTF::String> {
        auto output = decodeURIComponentSIMD(bytes);
        if (!output) {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        return WTF::move(*output);
    };
    if (args.input.is_string()) {
        auto utf8 = encodeUTF8ReplacingInvalidSequences(args.input.string());
        if (!utf8) {
            RELEASE_ASSERT(utf8.error() == UTF8ConversionError::OutOfMemory);
            JSC::throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        return decode({ reinterpret_cast<const uint8_t*>(utf8->span().data()), utf8->size() });
    }
    if (args.input.is_buffer())
        return decode({ args.input.buffer().unsafePtr("The entry frame holds the byte lease through synchronous URI decoding"_s), args.input.buffer().size() });

    RELEASE_ASSERT(args.input.is_ignored());
    return std::nullopt;
}

} // namespace Bun
