/*
    This file is part of the WebKit open source project.

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Library General Public
    License as published by the Free Software Foundation; either
    version 2 of the License, or (at your option) any later version.

    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Library General Public License for more details.

    You should have received a copy of the GNU Library General Public License
    along with this library; see the file COPYING.LIB.  If not, write to
    the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
    Boston, MA 02110-1301, USA.
*/

#include "config.h"
#include "JSBufferEncodingType.h"
#include <wtf/text/ASCIILiteral.h>

namespace WebCore {

std::optional<BufferEncodingType> parseBufferEncoding(const WTF::StringView& encoding)
{
    if (encoding.length() < 3)
        return std::nullopt;

    switch (encoding[0]) {
    case 'u':
    case 'U': {
        if (WTF::equalIgnoringASCIICase(encoding, "utf8"_s))
            return BufferEncodingType::utf8;
        if (WTF::equalIgnoringASCIICase(encoding, "utf-8"_s))
            return BufferEncodingType::utf8;
        if (WTF::equalIgnoringASCIICase(encoding, "ucs2"_s))
            return BufferEncodingType::ucs2;
        if (WTF::equalIgnoringASCIICase(encoding, "ucs-2"_s))
            return BufferEncodingType::ucs2;
        if (WTF::equalIgnoringASCIICase(encoding, "utf16le"_s))
            return BufferEncodingType::ucs2;
        if (WTF::equalIgnoringASCIICase(encoding, "utf-16le"_s))
            return BufferEncodingType::ucs2;
        break;
    }

    case 'l':
    case 'L': {
        if (WTF::equalIgnoringASCIICase(encoding, "latin1"_s))
            return BufferEncodingType::latin1;
        break;
    }

    case 'b':
    case 'B': {
        if (WTF::equalIgnoringASCIICase(encoding, "binary"_s))
            return BufferEncodingType::latin1; // BINARY is a deprecated alias of LATIN1.
        if (WTF::equalIgnoringASCIICase(encoding, "base64"_s))
            return BufferEncodingType::base64;
        if (WTF::equalIgnoringASCIICase(encoding, "base64url"_s))
            return BufferEncodingType::base64url;
        break;
    }

    case 'a':
    case 'A':
        // ascii
        if (WTF::equalLettersIgnoringASCIICase(encoding, "ascii"_s))
            return BufferEncodingType::ascii;
        break;

    case 'h':
    case 'H':
        // hex
        if (WTF::equalIgnoringASCIICase(encoding, "hex"_s))
            return BufferEncodingType::hex;
        break;
    }

    return std::nullopt;
}
} // namespace WebCore
