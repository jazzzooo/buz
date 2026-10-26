#include "root.h"
#include "HTTPHeaderNames.h"

namespace WTF {

static constexpr auto lowercaseHeaderNames = [] {
    std::array<std::array<char, WebCore::maxHTTPHeaderNameLength + 1>, WebCore::numHTTPHeaderNames> names {};
    for (size_t i = 0; i < names.size(); ++i) {
        const auto source = WebCore::httpHeaderNameEntries[i].name;
        for (size_t j = 0; j < source.size(); ++j)
            names[i][j] = isASCIIUpper(source[j]) ? static_cast<char>(source[j] + ('a' - 'A')) : source[j];
    }
    return names;
}();

template<bool lowercase, size_t... Index> static constexpr auto makeHeaderStringImpls(std::index_sequence<Index...>)
{
    return std::array {
        StringImpl::StaticStringImpl(ASCIILiteral::fromLiteralUnsafe(lowercase
                ? lowercaseHeaderNames[Index].data()
                : WebCore::httpHeaderNameEntries[Index].name.data()))...
    };
}

template<bool lowercase> static const String& headerString(WebCore::HTTPHeaderName name)
{
    static constinit auto impls = makeHeaderStringImpls<lowercase>(std::make_index_sequence<WebCore::numHTTPHeaderNames> {});
    static const auto strings = []<size_t... Index>(std::index_sequence<Index...>) {
        return std::array<NeverDestroyed<String>, sizeof...(Index)> {
            NeverDestroyed<String>(&static_cast<StringImpl&>(impls[Index]))...
        };
    }(std::make_index_sequence<WebCore::numHTTPHeaderNames> {});
    const auto index = static_cast<size_t>(name);
    RELEASE_ASSERT(index < strings.size());
    return strings[index];
}

const String& httpHeaderNameStringImpl(WebCore::HTTPHeaderName name)
{
    return headerString<true>(name);
}

const String& httpHeaderNameDefaultCaseStringImpl(WebCore::HTTPHeaderName name)
{
    return headerString<false>(name);
}

}
