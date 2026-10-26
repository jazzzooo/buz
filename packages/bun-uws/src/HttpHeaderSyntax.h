#pragma once

#include <string_view>

namespace uWS::HttpHeaderSyntax {

inline bool equalsIgnoringCase(std::string_view left, std::string_view right) {
    if (left.length() != right.length()) return false;
    for (size_t i = 0; i < left.length(); i++) {
        auto a = static_cast<unsigned char>(left[i]);
        auto b = static_cast<unsigned char>(right[i]);
        if (a >= 'A' && a <= 'Z') a += 'a' - 'A';
        if (b >= 'A' && b <= 'Z') b += 'a' - 'A';
        if (a != b) return false;
    }
    return true;
}

inline bool isTokenByte(unsigned char byte) {
    if ((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9')) return true;
    switch (byte) {
    case '!': case '#': case '$': case '%': case '&': case '\'': case '*':
    case '+': case '-': case '.': case '^': case '_': case '`': case '|': case '~':
        return true;
    default:
        return false;
    }
}

inline std::string_view trimOptionalWhitespace(std::string_view value) {
    while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) value.remove_prefix(1);
    while (!value.empty() && (value.back() == ' ' || value.back() == '\t')) value.remove_suffix(1);
    return value;
}

}
