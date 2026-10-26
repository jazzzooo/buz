#include "root.h"

#include "SchemaBindings.h"
#include "StringConversion.h"
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSGlobalObjectInlines.h>
#include <wtf/text/AtomString.h>
#include <wtf/text/MakeString.h>
#include <atomic>
#include <limits>
#include <unicode/utf8.h>
#include <wtf/SIMDUTF.h>
#include <wtf/unicode/UTF8Conversion.h>

using namespace JSC;

Expected<WTF::String, WTF::UTF8ConversionError> Bun::decodeUTF8ReplacingInvalidSequences(std::span<const uint8_t> input)
{
    if (input.empty())
        return WTF::emptyString();

    const size_t maxLength = std::min(stringSyntheticAllocationLimit(), static_cast<size_t>(WTF::String::MaxLength));
    if (simdutf::validate_ascii(reinterpret_cast<const char*>(input.data()), input.size())) {
        if (input.size() > maxLength)
            return WTF::makeUnexpected(WTF::UTF8ConversionError::OutOfMemory);
        std::span<Latin1Character> output;
        auto impl = WTF::StringImpl::tryCreateUninitialized(input.size(), output);
        if (!impl)
            return WTF::makeUnexpected(WTF::UTF8ConversionError::OutOfMemory);
        memcpy(output.data(), input.data(), input.size());
        return WTF::String(WTF::move(impl));
    }

    const auto nextCodePoint = [](std::span<const uint8_t>& remaining) -> char32_t {
        int32_t consumed = 0;
        const int32_t length = static_cast<int32_t>(std::min<size_t>(remaining.size(), U8_MAX_LENGTH));
        UChar32 codePoint;
        U8_NEXT(remaining.data(), consumed, length, codePoint);
        remaining = remaining.subspan(consumed);
        return codePoint < 0 ? 0xFFFD : static_cast<char32_t>(codePoint);
    };

    size_t length = 0;
    bool latin1 = true;
    for (auto remaining = input; !remaining.empty();) {
        const auto codePoint = nextCodePoint(remaining);
        const size_t width = U16_LENGTH(codePoint);
        if (width > maxLength - length)
            return WTF::makeUnexpected(WTF::UTF8ConversionError::OutOfMemory);
        length += width;
        latin1 &= codePoint <= 0xFF;
    }

    const auto decode = [&]<typename Character>() -> Expected<WTF::String, WTF::UTF8ConversionError> {
        std::span<Character> output;
        auto impl = WTF::StringImpl::tryCreateUninitialized(length, output);
        if (!impl)
            return WTF::makeUnexpected(WTF::UTF8ConversionError::OutOfMemory);
        size_t index = 0;
        for (auto remaining = input; !remaining.empty();) {
            const auto codePoint = nextCodePoint(remaining);
            if constexpr (sizeof(Character) == 1) {
                RELEASE_ASSERT(codePoint <= 0xFF && index < output.size());
                output[index++] = static_cast<Character>(codePoint);
            } else if (U_IS_BMP(codePoint)) {
                RELEASE_ASSERT(index < output.size());
                output[index++] = static_cast<char16_t>(codePoint);
            } else {
                RELEASE_ASSERT(output.size() - index >= 2);
                output[index++] = U16_LEAD(codePoint);
                output[index++] = U16_TRAIL(codePoint);
            }
        }
        RELEASE_ASSERT(index == output.size());
        return WTF::String(WTF::move(impl));
    };
    return latin1 ? decode.template operator()<Latin1Character>() : decode.template operator()<char16_t>();
}

Expected<WTF::Vector<uint8_t>, WTF::UTF8ConversionError> Bun::encodeUTF8ReplacingInvalidSequences(WTF::StringView source, UTF8Termination termination)
{
    WTF::Vector<uint8_t> output;
    size_t length = 0;
    if (!source.isEmpty()) {
        length = source.is8Bit()
            ? simdutf::utf8_length_from_latin1(reinterpret_cast<const char*>(source.span8().data()), source.length())
            : simdutf::utf8_length_from_utf16_with_replacement(source.span16()).count;
    }
    WTF::CheckedSize allocationLength = length;
    allocationLength += termination == UTF8Termination::Null;
    if (allocationLength.hasOverflowed() || !output.tryGrow(allocationLength.value()))
        return WTF::makeUnexpected(WTF::UTF8ConversionError::OutOfMemory);
    if (!source.isEmpty()) {
        std::span<char8_t> bytes { reinterpret_cast<char8_t*>(output.mutableSpan().data()), length };
        const auto converted = source.is8Bit()
            ? WTF::Unicode::convert(source.span8(), bytes)
            : WTF::Unicode::convertReplacingInvalidSequences(source.span16(), bytes);
        RELEASE_ASSERT(converted.code == WTF::Unicode::ConversionResultCode::Success);
        RELEASE_ASSERT(converted.buffer.size() == length);
    }
    if (termination == UTF8Termination::Null)
        output[length] = 0;
    return output;
}

static std::atomic_size_t stringSyntheticAllocationLimitValue { std::numeric_limits<uint32_t>::max() };

size_t Bun::stringSyntheticAllocationLimit()
{
    return stringSyntheticAllocationLimitValue.load(std::memory_order_relaxed);
}

void Bun::Bindgen::Engine::bunBindgenEngine_js_strings_setStringAllocationLimit(
    const BunBindgenEngine_js_strings_setStringAllocationLimit_Arguments& args)
{
    stringSyntheticAllocationLimitValue.store(args.value, std::memory_order_relaxed);
}

std::optional<WTF::String> Bun::Bindgen::Engine::bunBindgenEngine_js_strings_bunStringCreateAtomASCII(
    const Bun::Bindgen::Engine::BunBindgenEngine_js_strings_bunStringCreateAtomASCII_Arguments& args)
{
    ASSERT(simdutf::validate_ascii(reinterpret_cast<const char*>(args.input.data()), args.input.size()));
    auto atom = tryMakeAtomString(String(StringImpl::createWithoutCopying(
        { reinterpret_cast<const char*>(args.input.data()), args.input.size() })));
    if (atom.isNull())
        return std::nullopt;
    return WTF::String(atom.releaseImpl());
}

std::optional<WTF::String> Bun::Bindgen::Engine::bunBindgenEngine_js_strings_bunStringTryCreateAtomASCII(
    const Bun::Bindgen::Engine::BunBindgenEngine_js_strings_bunStringTryCreateAtomASCII_Arguments& args)
{
    if (simdutf::validate_ascii(reinterpret_cast<const char*>(args.input.data()), args.input.size())) {
        auto atom = tryMakeAtomString(String(StringImpl::createWithoutCopying(
            { reinterpret_cast<const char*>(args.input.data()), args.input.size() })));
        if (atom.isNull())
            return std::nullopt;
        return WTF::String(atom.releaseImpl());
    }

    return std::nullopt;
}

JSC::JSValue Bun::toJSArray(JSC::JSGlobalObject* globalObject, std::span<const WTF::String> values)
{
    if (values.empty())
        return JSC::constructEmptyArray(globalObject, nullptr);

    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    JSC::JSArray* array = constructEmptyArray(globalObject, nullptr, values.size());
    RETURN_IF_EXCEPTION(throwScope, {});

    for (size_t i = 0; i < values.size(); ++i) {
        const auto& value = values[i];
        auto* str = value.isEmpty() ? JSC::jsEmptyString(vm) : JSC::jsString(vm, value);
        RETURN_IF_EXCEPTION(throwScope, {});
        array->putDirectIndex(globalObject, i, str);
        RETURN_IF_EXCEPTION(throwScope, {});
    }

    return array;
}
