#pragma once

#include "ExceptionOr.h"
#include "StringConversion.h"
#include <algorithm>
#include <wtf/ASCIICType.h>
#include <wtf/KeyValuePair.h>

namespace WebCore::FormURLEncoding {

using Pairs = Vector<KeyValuePair<String, String>>;

inline ExceptionOr<String> decodeComponent(std::span<const uint8_t> input)
{
    Vector<uint8_t> bytes;
    if (std::ranges::any_of(input, [](uint8_t byte) { return byte == '%' || byte == '+'; })) {
        if (!bytes.tryReserveInitialCapacity(input.size()))
            return Exception { OutOfMemoryError };
        for (size_t index = 0; index < input.size(); ++index) {
            auto byte = input[index];
            if (byte == '+')
                byte = ' ';
            else if (byte == '%' && input.size() - index >= 3 && isASCIIHexDigit(input[index + 1]) && isASCIIHexDigit(input[index + 2])) {
                byte = toASCIIHexValue(input[index + 1], input[index + 2]);
                index += 2;
            }
            bytes.unsafeAppendWithoutCapacityCheck(byte);
        }
        input = bytes.span();
    }
    auto decoded = Bun::decodeUTF8ReplacingInvalidSequences(input);
    if (!decoded)
        return Exception { OutOfMemoryError };
    return WTF::move(decoded.value());
}

template<typename Append>
ExceptionOr<void> parse(std::span<const uint8_t> input, Append&& append)
{
    while (!input.empty()) {
        const size_t length = std::ranges::find(input, '&') - input.begin();
        const auto pair = input.first(length);
        input = length == input.size() ? std::span<const uint8_t> {} : input.subspan(length + 1);
        if (pair.empty())
            continue;
        const size_t nameLength = std::ranges::find(pair, '=') - pair.begin();
        auto name = decodeComponent(pair.first(nameLength));
        if (name.hasException())
            return name.releaseException();
        auto value = decodeComponent(nameLength == pair.size() ? std::span<const uint8_t> {} : pair.subspan(nameLength + 1));
        if (value.hasException())
            return value.releaseException();
        auto appended = append(name.releaseReturnValue(), value.releaseReturnValue());
        if (appended.hasException())
            return appended.releaseException();
    }
    return {};
}

inline ExceptionOr<Pairs> parse(StringView input)
{
    auto encoded = Bun::encodeUTF8ReplacingInvalidSequences(input);
    if (!encoded)
        return Exception { OutOfMemoryError };
    Pairs pairs;
    auto result = parse(encoded.value().span(), [&](String&& key, String&& value) -> ExceptionOr<void> {
        if (!pairs.tryAppend(KeyValuePair<String, String> { WTF::move(key), WTF::move(value) }))
            return Exception { OutOfMemoryError };
        return {};
    });
    if (result.hasException())
        return result.releaseException();
    return pairs;
}

inline ExceptionOr<void> appendComponent(Vector<Latin1Character>& output, StringView input)
{
    auto encoded = Bun::encodeUTF8ReplacingInvalidSequences(input);
    if (!encoded)
        return Exception { OutOfMemoryError };
    constexpr char hex[] = "0123456789ABCDEF";
    for (auto byte : encoded.value()) {
        if (isASCIIAlphanumeric(byte) || byte == '*' || byte == '-' || byte == '.' || byte == '_') {
            if (!output.tryAppend(byte))
                return Exception { OutOfMemoryError };
        } else if (byte == ' ') {
            if (!output.tryAppend('+'))
                return Exception { OutOfMemoryError };
        } else {
            const Latin1Character escaped[] = { '%', static_cast<Latin1Character>(hex[byte >> 4]), static_cast<Latin1Character>(hex[byte & 15]) };
            if (!output.tryAppend(std::span<const Latin1Character> { escaped }))
                return Exception { OutOfMemoryError };
        }
    }
    return {};
}

inline ExceptionOr<String> serialize(std::span<const KeyValuePair<String, String>> pairs)
{
    Vector<Latin1Character> output;
    bool first = true;
    for (const auto& pair : pairs) {
        if (!first && !output.tryAppend('&'))
            return Exception { OutOfMemoryError };
        first = false;
        auto name = appendComponent(output, pair.key);
        if (name.hasException())
            return name.releaseException();
        if (!output.tryAppend('='))
            return Exception { OutOfMemoryError };
        auto value = appendComponent(output, pair.value);
        if (value.hasException())
            return value.releaseException();
    }
    std::span<Latin1Character> characters;
    auto impl = StringImpl::tryCreateUninitialized(output.size(), characters);
    if (!impl)
        return Exception { OutOfMemoryError };
    std::ranges::copy(output, characters.begin());
    return String(WTF::move(impl));
}

} // namespace WebCore::FormURLEncoding
