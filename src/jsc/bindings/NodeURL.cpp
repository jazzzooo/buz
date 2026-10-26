#include "SchemaBindings.h"
#include <wtf/URL.h>
#include <wtf/URLParser.h>
#include <wtf/text/MakeString.h>
#include <wtf/unicode/icu/ICUHelpers.h>

namespace Bun::Bindgen::Engine {

BunBindgenEngine_NodeURL_convertDomain_Return bunBindgenEngine_NodeURL_convertDomain(
    const BunBindgenEngine_NodeURL_convertDomain_Arguments& args)
{
    if (args.domain.isEmpty())
        return WTF::String(WTF::emptyString());

    const bool ipv6 = args.domain.startsWith('[') && args.domain.endsWith(']');
    if (args.domain.contains([ipv6](char16_t character) {
            return WTF::isForbiddenHostCodePoint(character)
                && !(ipv6 && (character == '[' || character == ']' || character == ':'));
        }))
        return std::nullopt;

    WTF::URL url { WTF::makeString("http://"_s, args.domain, '/') };
    if (!url.isValid())
        return std::nullopt;
    if (ipv6)
        return url.host().toString();

    auto host = url.host();
    auto characters = host.upconvertedCharacters();
    const char16_t* input = characters;
    WTF::Vector<char16_t, 256> output;
    UIDNAInfo details = UIDNA_INFO_INITIALIZER;
    const auto convert = args.toASCII ? uidna_nameToASCII : uidna_nameToUnicode;
    auto status = WTF::callBufferProducingFunction(convert,
        &WTF::URLParser::internationalDomainNameTranscoder(), input, host.length(), output, &details);
    if (WTF::isICUMemoryAllocationError(status))
        return Bun::Bindgen::nativeAllocationFailure();
    if (U_FAILURE(status) || (details.errors & ~WTF::URLParser::allowedNameToASCIIErrors))
        return std::nullopt;
    return WTF::String(output.span());
}

} // namespace Bun::Bindgen::Engine
