#pragma once

#include <cstddef>
#include <cstdint>

namespace bun_image {

inline bool rgbaByteLength(size_t width, size_t height, size_t& out)
{
    if (!width || !height || width > SIZE_MAX / 4 || height > SIZE_MAX / (width * 4))
        return false;
    out = width * 4 * height;
    return true;
}

inline bool overlaps(const void* a, size_t aLength, const void* b, size_t bLength)
{
    const auto x = reinterpret_cast<uintptr_t>(a);
    const auto y = reinterpret_cast<uintptr_t>(b);
    return x <= y ? y - x < aLength : x - y < bLength;
}

inline bool validBuffers(const uint8_t* src, size_t srcLength, size_t srcRequired,
    uint8_t* dst, size_t dstLength, size_t dstRequired)
{
    return src && dst && srcLength >= srcRequired && dstLength >= dstRequired
        && !overlaps(src, srcRequired, dst, dstRequired);
}

}
