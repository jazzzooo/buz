/*
 * Authored by Alex Hultman, 2018-2021.
 * Intellectual property of third-party.

 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at

 *     http://www.apache.org/licenses/LICENSE-2.0

 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef UWS_WEBSOCKETEXTENSIONS_H
#define UWS_WEBSOCKETEXTENSIONS_H

#include "HttpHeaderSyntax.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <charconv>
#include <cstring>
#include <limits>
#include <optional>
#include <string_view>

namespace uWS {

struct ExtensionOffer {
    enum class Kind { Unsupported, PerMessageDeflate, WebKitDeflateFrame };
    Kind kind = Kind::Unsupported;
    bool valid = true;
    bool serverNoContextTakeover = false;
    bool clientNoContextTakeover = false;
    std::optional<unsigned int> serverMaxWindowBits;
    bool clientMaxWindowBitsOffered = false;
    std::optional<unsigned int> clientMaxWindowBits;
    bool noContextTakeover = false;
    std::optional<unsigned int> maxWindowBits;
};

struct ExtensionsParser {
private:
    std::string_view input;
    size_t position = 0;
    bool invalidSyntax = false;
    bool sawOffer = false;

    struct ParameterValue {
        bool present = false;
        std::optional<unsigned int> windowBits;
    };

    void skipWhitespace() {
        while (position < input.length() && (input[position] == ' ' || input[position] == '\t')) position++;
    }

    std::string_view token() {
        size_t start = position;
        while (position < input.length() && HttpHeaderSyntax::isTokenByte(static_cast<unsigned char>(input[position]))) position++;
        return input.substr(start, position - start);
    }

    bool value(ParameterValue &out) {
        out.present = true;
        bool quoted = position < input.length() && input[position] == '"';
        if (quoted) position++;
        unsigned int digits = 0;
        unsigned int number = 0;
        bool decimal = true;
        bool terminated = !quoted;
        while (position < input.length()) {
            unsigned char byte = static_cast<unsigned char>(input[position]);
            if (quoted && byte == '"') {
                position++;
                terminated = true;
                break;
            }
            if (!quoted && !HttpHeaderSyntax::isTokenByte(byte)) break;
            position++;
            if (quoted && byte == '\\') {
                if (position == input.length()) return false;
                byte = static_cast<unsigned char>(input[position++]);
            }
            if (!HttpHeaderSyntax::isTokenByte(byte)) return false;
            if (digits >= 2 || byte < '0' || byte > '9' || (digits == 0 && byte == '0')) decimal = false;
            if (decimal) number = number * 10 + byte - '0';
            if (digits < 3) digits++;
        }
        if (!terminated || digits == 0) return false;
        if (decimal && number >= 8 && number <= 15) out.windowBits = number;
        return true;
    }

    static void parameter(ExtensionOffer &offer, std::string_view name, const ParameterValue &value) {
        if (offer.kind == ExtensionOffer::Kind::PerMessageDeflate) {
            if (name == "server_no_context_takeover") {
                if (offer.serverNoContextTakeover || value.present) offer.valid = false;
                offer.serverNoContextTakeover = true;
            } else if (name == "client_no_context_takeover") {
                if (offer.clientNoContextTakeover || value.present) offer.valid = false;
                offer.clientNoContextTakeover = true;
            } else if (name == "server_max_window_bits") {
                if (offer.serverMaxWindowBits || !value.windowBits) offer.valid = false;
                offer.serverMaxWindowBits = value.windowBits;
            } else if (name == "client_max_window_bits") {
                if (offer.clientMaxWindowBitsOffered || (value.present && !value.windowBits)) offer.valid = false;
                offer.clientMaxWindowBitsOffered = true;
                offer.clientMaxWindowBits = value.windowBits;
            } else {
                offer.valid = false;
            }
        } else if (offer.kind == ExtensionOffer::Kind::WebKitDeflateFrame) {
            if (name == "no_context_takeover") {
                if (offer.noContextTakeover || value.present) offer.valid = false;
                offer.noContextTakeover = true;
            } else if (name == "max_window_bits") {
                if (offer.maxWindowBits || !value.windowBits) offer.valid = false;
                offer.maxWindowBits = value.windowBits;
            } else {
                offer.valid = false;
            }
        }
    }

public:
    explicit ExtensionsParser(std::string_view input) : input(input) {}

    bool malformed() const { return invalidSyntax; }

    bool next(ExtensionOffer &offer) {
        if (invalidSyntax) return false;
        skipWhitespace();
        while (position < input.length() && input[position] == ',') {
            position++;
            skipWhitespace();
        }
        if (position == input.length()) {
            if (!sawOffer && !input.empty()) invalidSyntax = true;
            return false;
        }
        auto name = token();
        if (name.empty()) { invalidSyntax = true; return false; }
        sawOffer = true;
        offer = {};
        if (name == "permessage-deflate") offer.kind = ExtensionOffer::Kind::PerMessageDeflate;
        else if (name == "x-webkit-deflate-frame") offer.kind = ExtensionOffer::Kind::WebKitDeflateFrame;
        for (;;) {
            skipWhitespace();
            if (position == input.length()) return true;
            if (input[position] == ',') { position++; return true; }
            if (input[position++] != ';') { invalidSyntax = true; return false; }
            skipWhitespace();
            auto parameterName = token();
            if (parameterName.empty()) { invalidSyntax = true; return false; }
            skipWhitespace();
            ParameterValue parameterValue;
            if (position < input.length() && input[position] == '=') {
                position++;
                skipWhitespace();
                if (!value(parameterValue)) { invalidSyntax = true; return false; }
            }
            parameter(offer, parameterName, parameterValue);
        }
    }
};

struct ExtensionResponse {
private:
    static constexpr size_t integerCapacity = std::numeric_limits<int>::digits10 + 2;
    static constexpr size_t capacity = std::max(
        sizeof("x-webkit-deflate-frame") - 1 + std::max(sizeof("; no_context_takeover") - 1, sizeof("; max_window_bits=") - 1 + integerCapacity),
        sizeof("permessage-deflate") - 1
            + std::max(sizeof("; client_no_context_takeover") - 1, sizeof("; client_max_window_bits=") - 1 + integerCapacity)
            + sizeof("; server_no_context_takeover") - 1
            + sizeof("; server_max_window_bits=") - 1 + integerCapacity);
    std::array<char, capacity> bytes{};
    size_t length = 0;

public:
    void append(std::string_view value) {
        assert(value.length() <= bytes.size() - length);
        memcpy(bytes.data() + length, value.data(), value.length());
        length += value.length();
    }

    void appendInteger(std::string_view prefix, int value) {
        append(prefix);
        char digits[integerCapacity];
        auto result = std::to_chars(digits, digits + sizeof(digits), value);
        assert(result.ec == std::errc());
        append({digits, static_cast<size_t>(result.ptr - digits)});
    }

    std::string_view view() const {
        return {bytes.data(), length};
    }
};

struct CompressionNegotiation {
    enum class Status { Declined, Accepted, InvalidHeader };
    Status status = Status::Declined;
    int compressionWindow = 0;
    int inflationWindow = 0;
    ExtensionResponse response{};
};

static inline CompressionNegotiation negotiateCompressionOffer(int wantedCompressionWindow, int wantedInflationWindow, const ExtensionOffer &ep) {
    if (!ep.valid || ep.kind == ExtensionOffer::Kind::Unsupported) return {};
    if ((wantedCompressionWindow != 0 && wantedCompressionWindow < 8) || wantedCompressionWindow > 15 ||
        (wantedInflationWindow != 0 && wantedInflationWindow < 8) || wantedInflationWindow > 15) return {};
#ifndef UWS_ALLOW_8_WINDOW_BITS
    if (wantedCompressionWindow == 8) return {};
#endif
    ExtensionResponse response;
    int compressionWindow = wantedCompressionWindow;
    int inflationWindow = wantedInflationWindow;

    if (ep.kind == ExtensionOffer::Kind::WebKitDeflateFrame) {
        response.append("x-webkit-deflate-frame");

        /* If the other peer has DEMANDED us no sliding window,
         * we cannot compress with anything other than shared compressor */
        if (ep.noContextTakeover) {
#ifndef UWS_ALLOW_SHARED_AND_DEDICATED_COMPRESSOR_MIX
            if (wantedCompressionWindow != 0) return {};
#endif

            compressionWindow = 0;
        }

        /* If the other peer has DEMANDED us to use a limited sliding window,
         * we have to limit out compression sliding window */
        if (ep.maxWindowBits) {
            if (compressionWindow == 0 && *ep.maxWindowBits < 15) return {};
            if (compressionWindow != 0) compressionWindow = std::min(compressionWindow, static_cast<int>(*ep.maxWindowBits));
#ifndef UWS_ALLOW_8_WINDOW_BITS
            if (compressionWindow == 8) return {};
#endif
        }

        /* We decide our own inflation sliding window (and their compression sliding window) */
        if (wantedInflationWindow < 15) {
            if (!wantedInflationWindow) {
                response.append("; no_context_takeover");
            } else {
                response.appendInteger("; max_window_bits=", wantedInflationWindow);
            }
        }
    } else {
        response.append("permessage-deflate");

        if (ep.clientNoContextTakeover) {
            inflationWindow = 0;
        } else if (ep.clientMaxWindowBits) {
            inflationWindow = std::min(inflationWindow, static_cast<int>(*ep.clientMaxWindowBits));
        }

        /* Whatever we have now, write */
        if (inflationWindow < 15) {
            if (!inflationWindow || !ep.clientMaxWindowBitsOffered) {
                response.append("; client_no_context_takeover");
                inflationWindow = 0;
            } else {
                response.appendInteger("; client_max_window_bits=", inflationWindow);
            }
        }

        if (ep.serverNoContextTakeover) {
#ifndef UWS_ALLOW_SHARED_AND_DEDICATED_COMPRESSOR_MIX
            if (wantedCompressionWindow != 0) return {};
#endif
            compressionWindow = 0;
        }
        if (ep.serverMaxWindowBits) {
            if (compressionWindow == 0 && *ep.serverMaxWindowBits < 15) return {};
            if (compressionWindow != 0) compressionWindow = std::min(compressionWindow, static_cast<int>(*ep.serverMaxWindowBits));
#ifndef UWS_ALLOW_8_WINDOW_BITS
            if (compressionWindow == 8) return {};
#endif
        }

        if (compressionWindow == 0) response.append("; server_no_context_takeover");
        if (ep.serverMaxWindowBits || (compressionWindow > 0 && compressionWindow < 15)) {
            response.appendInteger("; server_max_window_bits=", compressionWindow == 0 ? 15 : compressionWindow);
        }
    }

    return {CompressionNegotiation::Status::Accepted, compressionWindow, inflationWindow, response};
}

static inline CompressionNegotiation negotiateCompression(bool wantCompression, int wantedCompressionWindow, int wantedInflationWindow, std::string_view header) {
    ExtensionsParser parser(header);
    ExtensionOffer offer;
    CompressionNegotiation selected;
    while (parser.next(offer)) {
        if (wantCompression && selected.status != CompressionNegotiation::Status::Accepted) {
            selected = negotiateCompressionOffer(wantedCompressionWindow, wantedInflationWindow, offer);
        }
    }
    if (parser.malformed()) return {CompressionNegotiation::Status::InvalidHeader};
    return selected;
}

}

#endif // UWS_WEBSOCKETEXTENSIONS_H
