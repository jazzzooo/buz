#include "root.h"
#include "SchemaBindings.h"
#include <wtf/SIMDUTF.h>
#include <wtf/text/Base64.h>

namespace Bun::Bindgen::Cpp {

BunBindgenCpp_GlobalObjectHost_functionBTOA_Return::Type bunBindgenCpp_GlobalObjectHost_functionBTOA(
    CppCallContext&,
    const BunBindgenCpp_GlobalObjectHost_functionBTOA_Arguments& args)
{
    using Errors = BunBindgenCpp_GlobalObjectHost_functionBTOA_Return::Errors;
    auto value = args.value;
    if (value.isEmpty())
        return WTF::emptyString();
    if (!value.containsOnlyLatin1())
        return std::unexpected(Errors::invalid_character {});

    // btoa encodes Latin-1 bytes even when the string has UTF-16 storage.
    if (!value.is8Bit()) {
        std::span<Latin1Character> bytes;
        auto narrowed = WTF::String::tryCreateUninitialized(value.length(), bytes);
        if (narrowed.isNull())
            return nativeAllocationFailure();
        WTF::StringImpl::copyCharacters(bytes, value.span16());
        value = WTF::move(narrowed);
    }
    auto result = WTF::base64EncodeToStringReturnNullIfOverflow(std::as_bytes(value.span8()), {});
    if (result.isNull())
        return nativeAllocationFailure();
    return result;
}

BunBindgenCpp_GlobalObjectHost_functionATOB_Return::Type bunBindgenCpp_GlobalObjectHost_functionATOB(
    CppCallContext&,
    const BunBindgenCpp_GlobalObjectHost_functionATOB_Arguments& args)
{
    using Errors = BunBindgenCpp_GlobalObjectHost_functionATOB_Return::Errors;
    auto value = args.value;
    if (value.isEmpty())
        return WTF::emptyString();

    if (!value.is8Bit()) {
        auto characters = value.span16();
        size_t length = simdutf::latin1_length_from_utf16(characters.size());
        std::span<Latin1Character> bytes;
        auto narrowed = WTF::String::tryCreateUninitialized(length, bytes);
        if (narrowed.isNull())
            return nativeAllocationFailure();
        auto conversion = simdutf::convert_utf16le_to_latin1_with_errors(characters.data(), characters.size(), reinterpret_cast<char*>(bytes.data()));
        if (conversion.error)
            return std::unexpected(Errors::invalid_character {});
        value = WTF::move(narrowed);
    }

    auto input = value.span8();
    size_t length = simdutf::maximal_binary_length_from_base64(reinterpret_cast<const char*>(input.data()), input.size());
    std::span<Latin1Character> bytes;
    auto result = WTF::String::tryCreateUninitialized(length, bytes);
    if (result.isNull())
        return nativeAllocationFailure();
    auto conversion = simdutf::base64_to_binary(reinterpret_cast<const char*>(input.data()), input.size(), reinterpret_cast<char*>(bytes.data()), simdutf::base64_default);
    if (conversion.error != simdutf::error_code::SUCCESS)
        return std::unexpected(Errors::invalid_character {});
    if (conversion.count != length)
        return result.substringSharingImpl(0, conversion.count);
    return result;
}

}
