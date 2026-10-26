#ifndef UWS_H3RESPONSEDATA_H
#define UWS_H3RESPONSEDATA_H

#include "AsyncSocketData.h"
#include "HttpCallback.h"
#include "quic.h"

#include <wtf/Vector.h>
#include <climits>
#include <cstdint>
#include <cstring>

namespace uWS {

struct Http3Response;

struct Http3ResponseData {
    /* Same callback signatures as HttpResponseData so the C ABI matches. */
    using OnWritableCallback = bool (*)(Http3Response *, uint64_t, void *);
    using OnAbortedCallback = void (*)(Http3Response *, void *);
    using OnTimeoutCallback = void (*)(Http3Response *, void *);
    using OnDataCallback = void (*)(Http3Response *, const char *, size_t, bool, void *);

    /* Same bit values as HttpResponseData so uws_res_state() consumers
     * (Zig's State enum) work unchanged. */
    enum : uint8_t {
        HTTP_STATUS_CALLED = 1,
        HTTP_WRITE_CALLED = 2,
        HTTP_END_CALLED = 4,
        HTTP_RESPONSE_PENDING = 8,
        HTTP_CONNECTION_CLOSE = 16,
        HTTP_WROTE_CONTENT_LENGTH_HEADER = 32,
        HTTP_WROTE_DATE_HEADER = 64,
    };

    void *socketData = nullptr;
    HttpCallback<OnWritableCallback> onWritable;
    HttpCallback<OnAbortedCallback> onAborted;
    HttpCallback<OnDataCallback> inStream;
    HttpCallback<OnTimeoutCallback> onTimeout;

    struct StoredHeader {
        size_t nameOffset;
        size_t valueOffset;
        unsigned nameLength;
        unsigned valueLength;
    };
    ByteBuffer hdrBuf;
    WTF::Vector<StoredHeader, 16> hdrs;

    /* Body bytes the QUIC stream couldn't accept yet. */
    BackPressure backpressure;
    bool endAfterDrain = false;
    bool failed = false;

    uint64_t offset = 0;
    uint8_t state = 0;

    [[nodiscard]] bool tryAppendHeader(std::string_view name, std::string_view value, bool implicitStatus = false) {
        if (name.empty() || name.size() > UINT_MAX || value.size() > UINT_MAX) return false;
        const size_t count = implicitStatus ? 2 : 1;
        if (hdrs.size() > INT_MAX - count || !hdrs.tryReserveCapacity(hdrs.size() + count)) return false;
        const size_t off = hdrBuf.size();
        if (!hdrBuf.tryAppend({implicitStatus ? ":status200" : "", name, value})) return false;
        const size_t nameOffset = off + (implicitStatus ? 10 : 0);
        char *dst = hdrBuf.data() + nameOffset;
        for (size_t i = 0; i < name.size(); i++) {
            char c = dst[i];
            dst[i] = (char)(c | ((unsigned char)(c - 'A') < 26 ? 0x20 : 0));
        }
        if (implicitStatus) hdrs.append(StoredHeader{off, off + 7, 7, 3});
        hdrs.append(StoredHeader{nameOffset, nameOffset + name.size(), (unsigned) name.size(), (unsigned) value.size()});
        return true;
    }

    void reset() {
        onWritable.clear();
        onAborted.clear();
        inStream.clear();
        onTimeout.clear();
        hdrBuf.clear();
        hdrs.shrink(0);
        backpressure.clear();
        endAfterDrain = false;
        failed = false;
        offset = 0;
        state = HTTP_RESPONSE_PENDING;
    }
};

}

#endif
