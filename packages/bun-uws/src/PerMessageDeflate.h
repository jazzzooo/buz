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

/* This standalone module implements deflate / inflate streams */

#ifndef UWS_PERMESSAGEDEFLATE_H
#define UWS_PERMESSAGEDEFLATE_H

#define UWS_USE_LIBDEFLATE 1

#include <cstdint>
#include <cstring>

/* We always define these options no matter if ZLIB is enabled or not */
namespace uWS {
    /* Compressor mode is 8 lowest bits where HIGH4(windowBits), LOW4(memLevel).
     * Decompressor mode is 8 highest bits LOW4(windowBits).
     * If compressor or decompressor bits are 1, then they are shared.
     * If everything is just simply 0, then everything is disabled. */
    enum CompressOptions : uint16_t {
        /* These are not actual compression options */
        _COMPRESSOR_MASK = 0x00FF,
        _DECOMPRESSOR_MASK = 0x0F00,
        /* Disabled, shared, shared are "special" values */
        DISABLED = 0,
        SHARED_COMPRESSOR = 1,
        SHARED_DECOMPRESSOR = 1 << 8,
        /* Highest 4 bits describe decompressor */
        DEDICATED_DECOMPRESSOR_32KB = 15 << 8,
        DEDICATED_DECOMPRESSOR_16KB = 14 << 8,
        DEDICATED_DECOMPRESSOR_8KB = 13 << 8,
        DEDICATED_DECOMPRESSOR_4KB = 12 << 8,
        DEDICATED_DECOMPRESSOR_2KB = 11 << 8,
        DEDICATED_DECOMPRESSOR_1KB = 10 << 8,
        DEDICATED_DECOMPRESSOR_512B = 9 << 8,
        /* Same as 32kb */
        DEDICATED_DECOMPRESSOR = 15 << 8,

        /* Lowest 8 bit describe compressor */
        DEDICATED_COMPRESSOR_3KB = 9 << 4 | 1,
        DEDICATED_COMPRESSOR_4KB = 9 << 4 | 2,
        DEDICATED_COMPRESSOR_8KB = 10 << 4 | 3,
        DEDICATED_COMPRESSOR_16KB = 11 << 4 | 4,
        DEDICATED_COMPRESSOR_32KB = 12 << 4 | 5,
        DEDICATED_COMPRESSOR_64KB = 13 << 4 | 6,
        DEDICATED_COMPRESSOR_128KB = 14 << 4 | 7,
        DEDICATED_COMPRESSOR_256KB = 15 << 4 | 8,
        /* Same as 256kb */
        DEDICATED_COMPRESSOR = 15 << 4 | 8
    };
}

#if !defined(UWS_NO_ZLIB) && !defined(UWS_MOCK_ZLIB)
#include <zlib.h>
#endif

#include <string>
#include <optional>
#include <memory>
#include <new>

#ifdef UWS_USE_LIBDEFLATE
#include "libdeflate.h"
#include <cstring>
#endif

namespace uWS {

enum class CompressionError { None, OutOfMemory, InitializationFailed };

/* Do not compile this module if we don't want it */
#if defined(UWS_NO_ZLIB) || defined(UWS_MOCK_ZLIB)
struct ZlibContext {
    static std::unique_ptr<ZlibContext> create(CompressionError &error) {
        auto result = std::unique_ptr<ZlibContext>(new (std::nothrow) ZlibContext);
        error = result ? CompressionError::None : CompressionError::OutOfMemory;
        return result;
    }
};
struct InflationStream {
    std::optional<std::string_view> inflate(ZlibContext * /*zlibContext*/, std::string_view compressed, size_t maxPayloadLength, bool /*reset*/) {
        return compressed.substr(0, std::min(maxPayloadLength, compressed.length()));
    }
    static std::unique_ptr<InflationStream> create(CompressOptions, CompressionError &error) {
        auto result = std::unique_ptr<InflationStream>(new (std::nothrow) InflationStream);
        error = result ? CompressionError::None : CompressionError::OutOfMemory;
        return result;
    }
};
struct DeflationStream {
    std::string_view deflate(ZlibContext * /*zlibContext*/, std::string_view raw, bool /*reset*/) {
        return raw;
    }
    static std::unique_ptr<DeflationStream> create(CompressOptions, CompressionError &error) {
        auto result = std::unique_ptr<DeflationStream>(new (std::nothrow) DeflationStream);
        error = result ? CompressionError::None : CompressionError::OutOfMemory;
        return result;
    }
};
#else

static constexpr size_t LARGE_BUFFER_SIZE = 16 * 1024;

struct ZlibContext {
    /* Any returned data is valid until next same-class call.
     * We need to have two classes to allow inflation followed
     * by many deflations without modifying the inflation */
    std::string dynamicDeflationBuffer;
    std::string dynamicInflationBuffer;
    char deflationBuffer[LARGE_BUFFER_SIZE];
    char inflationBuffer[LARGE_BUFFER_SIZE];

#ifdef UWS_USE_LIBDEFLATE
    libdeflate_decompressor *decompressor = nullptr;
    libdeflate_compressor *compressor = nullptr;
#endif

private:
    ZlibContext() = default;
public:
    ZlibContext(const ZlibContext &) = delete;
    ZlibContext &operator=(const ZlibContext &) = delete;

    static std::unique_ptr<ZlibContext> create(CompressionError &error) {
        error = CompressionError::OutOfMemory;
        auto result = std::unique_ptr<ZlibContext>(new (std::nothrow) ZlibContext);
        if (!result) return nullptr;
#ifdef UWS_USE_LIBDEFLATE
        result->decompressor = libdeflate_alloc_decompressor();
        if (!result->decompressor) return nullptr;
        result->compressor = libdeflate_alloc_compressor(6);
        if (!result->compressor) return nullptr;
#endif
        error = CompressionError::None;
        return result;
    }

    ~ZlibContext() {
#ifdef UWS_USE_LIBDEFLATE
        if (decompressor) libdeflate_free_decompressor(decompressor);
        if (compressor) libdeflate_free_compressor(compressor);
#endif
    }
};

struct DeflationStream {
    z_stream deflationStream = {};
    bool initialized = false;
#ifdef UWS_USE_LIBDEFLATE
    unsigned char reset_buffer[4096 + 1];
#endif

private:
    DeflationStream() = default;
public:
    DeflationStream(const DeflationStream &) = delete;
    DeflationStream &operator=(const DeflationStream &) = delete;

    static std::unique_ptr<DeflationStream> create(CompressOptions compressOptions, CompressionError &error) {
        error = CompressionError::OutOfMemory;
        auto stream = std::unique_ptr<DeflationStream>(new (std::nothrow) DeflationStream);
        if (!stream) return nullptr;
        int windowBits = -(int) ((compressOptions & _COMPRESSOR_MASK) >> 4), memLevel = compressOptions & 0xF;
        const int result = deflateInit2(&stream->deflationStream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, memLevel, Z_DEFAULT_STRATEGY);
        if (result != Z_OK) {
            error = result == Z_MEM_ERROR ? CompressionError::OutOfMemory : CompressionError::InitializationFailed;
            return nullptr;
        }
        stream->initialized = true;
        error = CompressionError::None;
        return stream;
    }

    /* Deflate and optionally reset. You must not deflate an empty string. */
    std::string_view deflate(ZlibContext *zlibContext, std::string_view raw, bool reset) {

#ifdef UWS_USE_LIBDEFLATE
        /* Run a fast path in case of shared_compressor */
        if (reset) {
            size_t written = 0;
            written = libdeflate_deflate_compress(zlibContext->compressor, raw.data(), raw.length(), reset_buffer, 4096);

            if (written) {
                memcpy(&reset_buffer[written], "\x00", 1);
                return std::string_view((char *) reset_buffer, written + 1);
            }
        }
#endif

        /* Odd place to clear this one, fix */
        zlibContext->dynamicDeflationBuffer.clear();

        deflationStream.next_in = (Bytef *) raw.data();
        deflationStream.avail_in = (unsigned int) raw.length();

        /* This buffer size has to be at least 6 bytes for Z_SYNC_FLUSH to work */
        const int DEFLATE_OUTPUT_CHUNK = LARGE_BUFFER_SIZE;

        int err;
        do {
            deflationStream.next_out = (Bytef *) zlibContext->deflationBuffer;
            deflationStream.avail_out = DEFLATE_OUTPUT_CHUNK;

            err = ::deflate(&deflationStream, Z_SYNC_FLUSH);
            if (Z_OK == err && deflationStream.avail_out == 0) {
                zlibContext->dynamicDeflationBuffer.append(zlibContext->deflationBuffer, DEFLATE_OUTPUT_CHUNK - deflationStream.avail_out);
                continue;
            } else {
                break;
            }
        } while (true);

        /* This must not change avail_out */
        if (reset) {
            deflateReset(&deflationStream);
        }

        if (zlibContext->dynamicDeflationBuffer.length()) {
            zlibContext->dynamicDeflationBuffer.append(zlibContext->deflationBuffer, DEFLATE_OUTPUT_CHUNK - deflationStream.avail_out);

            return std::string_view((char *) zlibContext->dynamicDeflationBuffer.data(), zlibContext->dynamicDeflationBuffer.length() - 4);
        }

        /* Note: We will get an interger overflow resulting in heap buffer overflow if Z_BUF_ERROR is returned
         * from passing 0 as avail_in. Therefore we must not deflate an empty string */
        return {
            zlibContext->deflationBuffer,
            DEFLATE_OUTPUT_CHUNK - deflationStream.avail_out - 4
        };
    }

    ~DeflationStream() {
        if (initialized) deflateEnd(&deflationStream);
    }
};

struct InflationStream {
    z_stream inflationStream = {};
    bool initialized = false;
#ifdef UWS_USE_LIBDEFLATE
    char buf[4096];
#endif

private:
    InflationStream() = default;
public:
    InflationStream(const InflationStream &) = delete;
    InflationStream &operator=(const InflationStream &) = delete;

    static std::unique_ptr<InflationStream> create(CompressOptions compressOptions, CompressionError &error) {
        error = CompressionError::OutOfMemory;
        auto stream = std::unique_ptr<InflationStream>(new (std::nothrow) InflationStream);
        if (!stream) return nullptr;
        const int result = inflateInit2(&stream->inflationStream, -(compressOptions >> 8));
        if (result != Z_OK) {
            error = result == Z_MEM_ERROR ? CompressionError::OutOfMemory : CompressionError::InitializationFailed;
            return nullptr;
        }
        stream->initialized = true;
        error = CompressionError::None;
        return stream;
    }

    ~InflationStream() {
        if (initialized) inflateEnd(&inflationStream);
    }

    /* Zero length inflates are possible and valid */
    std::optional<std::string_view> inflate(ZlibContext *zlibContext, std::string_view compressed, size_t maxPayloadLength, bool reset) {

#ifdef UWS_USE_LIBDEFLATE
        /* Try fast path first */
        size_t written = 0;

        /* We have to pad 9 bytes and restore those bytes when done since 9 is more than 6 of next WebSocket message */
        char tmp[9];
        memcpy(tmp, (char *) compressed.data() + compressed.length(), 9);
        memcpy((char *) compressed.data() + compressed.length(), "\x00\x00\xff\xff\x01\x00\x00\xff\xff", 9);
        libdeflate_result res = libdeflate_deflate_decompress(zlibContext->decompressor, compressed.data(), compressed.length() + 9, buf, 4096, &written);
        memcpy((char *) compressed.data() + compressed.length(), tmp, 9);

        if (res == 0) {
            /* Fast path wins */
            return std::string_view(buf, written);
        }
#endif

        /* Save off the bytes we're about to overwrite */
        char* tailLocation = (char*)compressed.data() + compressed.length();
        char preTailBytes[4];
        memcpy(preTailBytes, tailLocation, 4);

        /* Append tail to chunk */
        unsigned char tail[4] = {0x00, 0x00, 0xff, 0xff};
        memcpy(tailLocation, tail, 4);
        compressed = {compressed.data(), compressed.length() + 4};

        /* We clear this one here, could be done better */
        zlibContext->dynamicInflationBuffer.clear();

        inflationStream.next_in = (Bytef *) compressed.data();
        inflationStream.avail_in = (unsigned int) compressed.length();

        int err;
        do {
            inflationStream.next_out = (Bytef *) zlibContext->inflationBuffer;
            inflationStream.avail_out = LARGE_BUFFER_SIZE;

            err = ::inflate(&inflationStream, Z_SYNC_FLUSH);
            if (err == Z_OK && inflationStream.avail_out) {
                break;
            }

            zlibContext->dynamicInflationBuffer.append(zlibContext->inflationBuffer, LARGE_BUFFER_SIZE - inflationStream.avail_out);


        } while (inflationStream.avail_out == 0 && zlibContext->dynamicInflationBuffer.length() <= maxPayloadLength);

        if (reset) {
            inflateReset(&inflationStream);
        }

        /* Restore the bytes we used for the tail */
        memcpy(tailLocation, preTailBytes, 4);

        if ((err != Z_BUF_ERROR && err != Z_OK) || zlibContext->dynamicInflationBuffer.length() > maxPayloadLength) {
            return std::nullopt;
        }

        if (zlibContext->dynamicInflationBuffer.length()) {
            zlibContext->dynamicInflationBuffer.append(zlibContext->inflationBuffer, LARGE_BUFFER_SIZE - inflationStream.avail_out);

            /* Let's be strict about the max size */
            if (zlibContext->dynamicInflationBuffer.length() > maxPayloadLength) {
                return std::nullopt;
            }

            return std::string_view(zlibContext->dynamicInflationBuffer.data(), zlibContext->dynamicInflationBuffer.length());
        }

        /* Let's be strict about the max size */
        if ((LARGE_BUFFER_SIZE - inflationStream.avail_out) > maxPayloadLength) {
            return std::nullopt;
        }

        return std::string_view(zlibContext->inflationBuffer, LARGE_BUFFER_SIZE - inflationStream.avail_out);
    }

};

#endif

}

#endif // UWS_PERMESSAGEDEFLATE_H
