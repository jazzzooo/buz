#ifndef UWS_H3RESPONSE_H
#define UWS_H3RESPONSE_H

#include "quic.h"
#include "Http3ResponseData.h"
#include "HttpHeaderSyntax.h"
#include "LoopData.h"
#include "MoveOnlyFunction.h"

#include <algorithm>
#include <charconv>
#include <optional>
#include <string_view>

namespace uWS {

struct Http3Response {
    enum class WriteStatus { Complete, Backpressure, OutOfMemory, Failed };

    Http3ResponseData *getHttpResponseData() {
        return static_cast<Http3ResponseData *>(us_quic_stream_ext(native()));
    }

    [[nodiscard]] WriteStatus writeStatus(std::string_view status) {
        auto *d = getHttpResponseData();
        if (d->failed) return WriteStatus::Failed;
        if (d->state & Http3ResponseData::HTTP_STATUS_CALLED) return WriteStatus::Complete;
        const auto code = status.size() >= 3 ? status.substr(0, 3) : std::string_view("200");
        if (!d->tryAppendHeader(":status", code)) return WriteStatus::OutOfMemory;
        d->state |= Http3ResponseData::HTTP_STATUS_CALLED;
        return WriteStatus::Complete;
    }

    [[nodiscard]] WriteStatus writeHeader(std::string_view name, std::string_view value) {
        auto *d = getHttpResponseData();
        if (d->failed) return WriteStatus::Failed;
        if (d->state & Http3ResponseData::HTTP_WRITE_CALLED) return WriteStatus::Complete;
        if (name.empty() || name.size() > UINT_MAX || value.size() > UINT_MAX) return fail(d);
        const bool implicitStatus = !(d->state & Http3ResponseData::HTTP_STATUS_CALLED);
        const bool contentLength = HttpHeaderSyntax::equalsIgnoringCase(name, "content-length");
        const bool date = HttpHeaderSyntax::equalsIgnoringCase(name, "date");
        if (!d->tryAppendHeader(name, value, implicitStatus)) return WriteStatus::OutOfMemory;
        d->state |= Http3ResponseData::HTTP_STATUS_CALLED;
        if (contentLength) d->state |= Http3ResponseData::HTTP_WROTE_CONTENT_LENGTH_HEADER;
        if (date) d->state |= Http3ResponseData::HTTP_WROTE_DATE_HEADER;
        return WriteStatus::Complete;
    }

    [[nodiscard]] WriteStatus writeHeader(std::string_view name, uint64_t value) {
        char bytes[24];
        const auto result = std::to_chars(bytes, bytes + sizeof(bytes), value);
        return writeHeader(name, std::string_view(bytes, result.ptr - bytes));
    }

    [[nodiscard]] WriteStatus writeMark() {
        auto *d = getHttpResponseData();
        if (d->failed) return WriteStatus::Failed;
        if (d->state & Http3ResponseData::HTTP_WROTE_DATE_HEADER) return WriteStatus::Complete;
        auto *loop = us_quic_socket_context_loop(us_quic_stream_context(native()));
        auto *data = static_cast<LoopData *>(us_loop_ext(loop));
        return writeHeader("date", std::string_view(data->date, 29));
    }

    [[nodiscard]] WriteStatus writeContinue() {
        auto *d = getHttpResponseData();
        if (d->failed) return WriteStatus::Failed;
        return headerResult(d, us_quic_stream_send_informational(native(), "100"));
    }

    [[nodiscard]] WriteStatus flushHeaders(bool = false) {
        auto *d = getHttpResponseData();
        if (d->failed) return WriteStatus::Failed;
        if (d->state & Http3ResponseData::HTTP_WRITE_CALLED) return WriteStatus::Complete;
        const auto status = writeStatus("200 OK");
        if (status != WriteStatus::Complete) return status;
        return sendBufferedHeaders(d, false);
    }

    [[nodiscard]] WriteStatus write(std::string_view data, size_t *written = nullptr) {
        if (written) *written = 0;
        auto *d = getHttpResponseData();
        if (d->failed) return WriteStatus::Failed;
        if (!(d->state & Http3ResponseData::HTTP_RESPONSE_PENDING)) return WriteStatus::Complete;
        const auto status = flushHeaders();
        if (status != WriteStatus::Complete) return status;
        return writeBody(d, data, false, written);
    }

    [[nodiscard]] WriteStatus end(std::string_view data = {}, bool = false) {
        return internalEnd(data, std::nullopt, data.size());
    }

    [[nodiscard]] WriteStatus tryEnd(std::string_view data, uint64_t totalSize = 0, bool = false) {
        return internalEnd(data, totalSize, totalSize);
    }

    [[nodiscard]] WriteStatus endWithoutBody(std::optional<size_t> reportedContentLength = std::nullopt, bool = false) {
        return internalEnd({}, std::nullopt, reportedContentLength);
    }

    [[nodiscard]] WriteStatus sendTerminatingChunk(bool = false) {
        return internalEnd({}, std::nullopt, std::nullopt);
    }

    bool hasResponded() { return !(getHttpResponseData()->state & Http3ResponseData::HTTP_RESPONSE_PENDING); }
    uint64_t getWriteOffset() { return getHttpResponseData()->offset; }
    void overrideWriteOffset(uint64_t offset) { getHttpResponseData()->offset = offset; }
    void setWriteOffset(uint64_t offset) { overrideWriteOffset(offset); }
    size_t getBufferedAmount() { return getHttpResponseData()->backpressure.length(); }

    Http3Response *pause() { us_quic_stream_want_read(native(), 0); return this; }
    Http3Response *resume() { us_quic_stream_want_read(native(), 1); return this; }
    Http3Response *cork(MoveOnlyFunction<void()> &&fn) { fn(); return this; }
    void uncork() {}
    bool isCorked() { return false; }
    void close() { us_quic_stream_reset(native()); }
    void *getNativeHandle() { return this; }
    void *getSocketData() { return getHttpResponseData()->socketData; }
    bool isConnectRequest() { return false; }
    void setTimeout(uint8_t) {}
    void resetTimeout() {}

    Http3Response *onWritable(void *context, Http3ResponseData::OnWritableCallback handler) {
        getHttpResponseData()->onWritable.set(context, handler);
        return this;
    }
    Http3Response *clearOnWritable() { getHttpResponseData()->onWritable.clear(); return this; }
    Http3Response *onAborted(void *context, Http3ResponseData::OnAbortedCallback handler) {
        getHttpResponseData()->onAborted.set(context, handler);
        return this;
    }
    Http3Response *clearOnAborted() { getHttpResponseData()->onAborted.clear(); return this; }
    Http3Response *onTimeout(void *context, Http3ResponseData::OnTimeoutCallback handler) {
        getHttpResponseData()->onTimeout.set(context, handler);
        return this;
    }
    Http3Response *clearOnTimeout() { getHttpResponseData()->onTimeout.clear(); return this; }
    void onData(void *context, Http3ResponseData::OnDataCallback handler) {
        getHttpResponseData()->inStream.set(context, handler);
    }
    Http3Response *clearOnWritableAndAborted() {
        // Stream teardown must still notify its holder through onAborted.
        return clearOnWritable();
    }

    [[nodiscard]] WriteStatus drain() {
        auto *d = getHttpResponseData();
        if (d->failed) return WriteStatus::Failed;
        while (d->backpressure.length()) {
            const auto size = static_cast<unsigned>(std::min(d->backpressure.length(), size_t(INT_MAX)));
            const int written = us_quic_stream_write(native(), d->backpressure.data(), size);
            if (written < 0) return fail(d);
            if (!written) return WriteStatus::Backpressure;
            d->backpressure.erase(static_cast<size_t>(written));
        }
        if (d->endAfterDrain) {
            d->endAfterDrain = false;
            if (us_quic_stream_shutdown(native()) < 0) return fail(d);
            return WriteStatus::Complete;
        }
        if (d->onWritable) return d->onWritable(this, d->offset) ? WriteStatus::Complete : WriteStatus::Backpressure;
        return WriteStatus::Complete;
    }

private:
    us_quic_stream_t *native() { return reinterpret_cast<us_quic_stream_t *>(this); }

    static WriteStatus fail(Http3ResponseData *d) {
        d->failed = true;
        return WriteStatus::Failed;
    }

    static WriteStatus headerResult(Http3ResponseData *d, us_quic_header_status_t status) {
        switch (status) {
        case US_QUIC_HEADERS_SUCCESS: return WriteStatus::Complete;
        case US_QUIC_HEADERS_OUT_OF_MEMORY: return WriteStatus::OutOfMemory;
        case US_QUIC_HEADERS_INVALID:
        case US_QUIC_HEADERS_STREAM_ERROR: return fail(d);
        }
        std::abort();
    }

    WriteStatus sendBufferedHeaders(Http3ResponseData *d, bool endStream) {
        WTF::Vector<us_quic_header_t, 16> headers;
        if (!headers.tryReserveCapacity(d->hdrs.size())) return WriteStatus::OutOfMemory;
        for (const auto &header : d->hdrs) {
            headers.append(us_quic_header_t{d->hdrBuf.data() + header.nameOffset, header.nameLength,
                d->hdrBuf.data() + header.valueOffset, header.valueLength, -1});
        }
        const auto status = headerResult(d, us_quic_stream_send_headers(native(), headers.span().data(), static_cast<unsigned>(headers.size()), endStream));
        if (status != WriteStatus::Complete) return status;
        d->state |= Http3ResponseData::HTTP_WRITE_CALLED;
        d->hdrBuf.clear();
        d->hdrs.clear();
        return WriteStatus::Complete;
    }

    WriteStatus writeBody(Http3ResponseData *d, std::string_view data, bool optional, size_t *written) {
        size_t accepted = 0;
        if (data.size() > UINT64_MAX - d->offset) return fail(d);
        while (!data.empty()) {
            if (!d->backpressure.length()) {
                const unsigned size = static_cast<unsigned>(std::min(data.size(), size_t(INT_MAX)));
                const int count = us_quic_stream_write(native(), data.data(), size);
                if (count < 0) return fail(d);
                d->offset += static_cast<unsigned>(count);
                accepted += static_cast<unsigned>(count);
                if (written) *written = accepted;
                data.remove_prefix(static_cast<unsigned>(count));
                if (static_cast<unsigned>(count) == size) continue;
            }
            if (!optional) {
                if (!d->backpressure.tryAppend(data.data(), data.size())) return WriteStatus::OutOfMemory;
                d->offset += data.size();
                accepted += data.size();
                if (written) *written = accepted;
            }
            us_quic_stream_want_write(native(), 1);
            return WriteStatus::Backpressure;
        }
        return WriteStatus::Complete;
    }

    WriteStatus internalEnd(std::string_view data, std::optional<uint64_t> totalSize, std::optional<uint64_t> contentLength) {
        auto *d = getHttpResponseData();
        if (d->failed) return WriteStatus::Failed;
        if (!(d->state & Http3ResponseData::HTTP_RESPONSE_PENDING)) return WriteStatus::Complete;
        if (!(d->state & Http3ResponseData::HTTP_WRITE_CALLED)) {
            auto status = writeStatus("200 OK");
            if (status != WriteStatus::Complete) return status;
            if (contentLength && !(d->state & Http3ResponseData::HTTP_WROTE_CONTENT_LENGTH_HEADER)) {
                status = writeHeader("content-length", *contentLength);
                if (status != WriteStatus::Complete) return status;
            }
            const bool endStream = data.empty() && (!totalSize || d->offset == *totalSize);
            status = sendBufferedHeaders(d, endStream);
            if (status != WriteStatus::Complete) return status;
            if (endStream) {
                markDone(d);
                return WriteStatus::Complete;
            }
        }
        const auto status = writeBody(d, data, totalSize.has_value(), nullptr);
        if (status == WriteStatus::OutOfMemory || status == WriteStatus::Failed) return status;
        if (totalSize && d->offset != *totalSize) return status;
        if (d->backpressure.length()) {
            d->endAfterDrain = true;
            us_quic_stream_want_write(native(), 1);
        } else {
            if (us_quic_stream_shutdown(native()) < 0) return fail(d);
        }
        markDone(d);
        return WriteStatus::Complete;
    }

    void markDone(Http3ResponseData *d) {
        d->onWritable.clear();
        d->inStream.clear();
        d->onTimeout.clear();
        // onAborted also reports completed stream teardown so holders can discard their pointers.
        d->state |= Http3ResponseData::HTTP_END_CALLED;
        d->state &= ~Http3ResponseData::HTTP_RESPONSE_PENDING;
        us_quic_stream_shutdown_read(native());
    }
};

}

#endif
