#pragma once

#include "LoopData.h"
#include "ByteBuffer.h"
#include "PerMessageDeflate.h"
#include "WebSocketExtensions.h"
#include "WebSocketHandshake.h"
#include <memory>
#include <optional>

namespace uWS {

enum class WebSocketUpgradeError { None, OutOfMemory, InvalidExtensions, CompressionInitializationFailed, InvalidKey, InvalidProtocol, InvalidResponseState };

struct PreparedWebSocketUpgrade {
    ByteBuffer output;
    bool needsDate = true;
    bool ready = false;
    CompressionNegotiation negotiation;
    std::unique_ptr<DeflationStream> deflation;
    std::unique_ptr<InflationStream> inflation;

    [[nodiscard]] bool addHeader(std::string_view name, std::string_view value) {
        RELEASE_ASSERT(!ready);
        if (!output.tryAppend({name, ": ", value, "\r\n"})) return false;
        if (HttpHeaderSyntax::equalsIgnoringCase(name, "Date")) needsDate = false;
        return true;
    }

    [[nodiscard]] bool finish(std::string_view date, std::string_view backpressure, std::string_view corked) {
        RELEASE_ASSERT(!ready);
        ByteBuffer complete;
        if (!complete.tryAppend({backpressure, corked, output.view(), needsDate ? "Date: " : "",
                needsDate ? date : std::string_view(), needsDate ? "\r\n\r\n" : "\r\n"})) return false;
        output = std::move(complete);
        ready = true;
        return true;
    }

    static std::optional<PreparedWebSocketUpgrade> prepare(LoopData *loop, CompressOptions configured,
            std::string_view key, std::string_view protocols, std::string_view extensions,
            bool needsStatus, bool needsDate, WebSocketUpgradeError &error) {
        error = WebSocketUpgradeError::None;
        PreparedWebSocketUpgrade prepared;
        prepared.needsDate = needsDate;
        std::array<char, 28> accept;
        if (!WebSocketHandshake::generate(key, accept)) {
            error = WebSocketUpgradeError::InvalidKey;
            return std::nullopt;
        }
        std::string_view selectedProtocol;
        auto remainingProtocols = protocols;
        while (!remainingProtocols.empty()) {
            const auto comma = remainingProtocols.find(',');
            const auto candidate = HttpHeaderSyntax::trimOptionalWhitespace(remainingProtocols.substr(0, comma));
            if (!std::all_of(candidate.begin(), candidate.end(), HttpHeaderSyntax::isTokenByte)) {
                error = WebSocketUpgradeError::InvalidProtocol;
                return std::nullopt;
            }
            if (selectedProtocol.empty()) selectedProtocol = candidate;
            if (comma == std::string_view::npos) break;
            remainingProtocols.remove_prefix(comma + 1);
        }
        if (!protocols.empty() && selectedProtocol.empty()) {
            error = WebSocketUpgradeError::InvalidProtocol;
            return std::nullopt;
        }
        int compressionWindow = (configured & CompressOptions::_COMPRESSOR_MASK) == CompressOptions::SHARED_COMPRESSOR
            ? 0 : (configured & CompressOptions::_COMPRESSOR_MASK) >> 4;
        int inflationWindow = (configured & CompressOptions::_DECOMPRESSOR_MASK) == CompressOptions::SHARED_DECOMPRESSOR
            ? 0 : (configured & CompressOptions::_DECOMPRESSOR_MASK) >> 8;
        prepared.negotiation = negotiateCompression(configured != CompressOptions::DISABLED, compressionWindow, inflationWindow, extensions);
        if (prepared.negotiation.status == CompressionNegotiation::Status::InvalidHeader) {
            error = WebSocketUpgradeError::InvalidExtensions;
            return std::nullopt;
        }

        if (!prepared.output.tryAppend({needsStatus ? "HTTP/1.1 101 Switching Protocols\r\n" : ""}) ||
            !prepared.addHeader("Upgrade", "websocket") ||
            !prepared.addHeader("Connection", "Upgrade") ||
            !prepared.addHeader("Sec-WebSocket-Accept", std::string_view(accept.data(), accept.size())) ||
            (!selectedProtocol.empty() && !prepared.addHeader("Sec-WebSocket-Protocol", selectedProtocol)) ||
            (prepared.negotiation.status == CompressionNegotiation::Status::Accepted &&
                !prepared.addHeader("Sec-WebSocket-Extensions", prepared.negotiation.response.view()))) {
            error = WebSocketUpgradeError::OutOfMemory;
            return std::nullopt;
        }
        if (prepared.negotiation.status != CompressionNegotiation::Status::Accepted) return prepared;

        CompressionError compressionError;
        auto fail = [&]() -> std::optional<PreparedWebSocketUpgrade> {
            error = compressionError == CompressionError::OutOfMemory
                ? WebSocketUpgradeError::OutOfMemory : WebSocketUpgradeError::CompressionInitializationFailed;
            return std::nullopt;
        };
        if (!loop->ensureCompression(compressionError)) return fail();
        const int negotiatedCompressionWindow = prepared.negotiation.compressionWindow;
        if (negotiatedCompressionWindow != 0) {
            auto options = static_cast<CompressOptions>((negotiatedCompressionWindow << 4) | (negotiatedCompressionWindow - 7));
            if ((configured & CompressOptions::_COMPRESSOR_MASK) == CompressOptions::DEDICATED_COMPRESSOR_3KB) options = CompressOptions::DEDICATED_COMPRESSOR_3KB;
            prepared.deflation = DeflationStream::create(options, compressionError);
            if (!prepared.deflation) return fail();
        }
        const int negotiatedInflationWindow = prepared.negotiation.inflationWindow;
        if (negotiatedInflationWindow != 0) {
            prepared.inflation = InflationStream::create(static_cast<CompressOptions>(negotiatedInflationWindow << 8), compressionError);
            if (!prepared.inflation) return fail();
        }
        return prepared;
    }
};

}
