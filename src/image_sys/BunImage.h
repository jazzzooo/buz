#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#define BUN_IMAGE_NOEXCEPT noexcept
extern "C" {
#else
#define BUN_IMAGE_NOEXCEPT
#endif

typedef uint8_t BunImageStatus;
enum {
    BUN_IMAGE_OK = 0,
    BUN_IMAGE_UNAVAILABLE = 1,
    BUN_IMAGE_INVALID_INPUT = 2,
    BUN_IMAGE_DECODE_FAILED = 3,
    BUN_IMAGE_ENCODE_FAILED = 4,
    BUN_IMAGE_TOO_MANY_PIXELS = 5,
    BUN_IMAGE_OUT_OF_MEMORY = 6,
};

typedef uint8_t BunImageFilter;
enum {
    BUN_IMAGE_FILTER_BOX = 0,
    BUN_IMAGE_FILTER_BILINEAR = 1,
    BUN_IMAGE_FILTER_LANCZOS3 = 2,
    BUN_IMAGE_FILTER_MITCHELL = 3,
    BUN_IMAGE_FILTER_NEAREST = 4,
    BUN_IMAGE_FILTER_CUBIC = 5,
    BUN_IMAGE_FILTER_LANCZOS2 = 6,
    BUN_IMAGE_FILTER_MKS2013 = 7,
    BUN_IMAGE_FILTER_MKS2021 = 8,
};

typedef uint8_t BunImageFormat;
enum {
    BUN_IMAGE_FORMAT_HEIC = 0,
    BUN_IMAGE_FORMAT_AVIF = 1,
};

BunImageStatus bun_image_resize_scratch_size(uint32_t src_width, uint32_t src_height,
    uint32_t dst_width, uint32_t dst_height, BunImageFilter filter, size_t* out_size) BUN_IMAGE_NOEXCEPT;

/* Input, output, and scratch must be disjoint. Scratch may have any alignment. */
BunImageStatus bun_image_resize_rgba8(const uint8_t* src, size_t src_len,
    uint32_t src_width, uint32_t src_height, uint8_t* dst, size_t dst_len,
    uint32_t dst_width, uint32_t dst_height, BunImageFilter filter,
    uint8_t* scratch, size_t scratch_len) BUN_IMAGE_NOEXCEPT;
BunImageStatus bun_image_rotate_rgba8(const uint8_t* src, size_t src_len,
    uint32_t width, uint32_t height, uint8_t* dst, size_t dst_len, uint8_t quarters) BUN_IMAGE_NOEXCEPT;
BunImageStatus bun_image_flip_rgba8(const uint8_t* src, size_t src_len,
    uint32_t width, uint32_t height, uint8_t* dst, size_t dst_len, uint8_t horizontal) BUN_IMAGE_NOEXCEPT;
void bun_image_modulate_rgba8(uint8_t* rgba, size_t len, float brightness, float saturation) BUN_IMAGE_NOEXCEPT;

/* Palette contains count RGBA8 entries, with 1 <= count <= 256. */
uint8_t bun_image_nearest_palette(const uint8_t* palette, uint16_t count,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a) BUN_IMAGE_NOEXCEPT;

typedef struct CGImage BunCGImage;
typedef struct __CFData BunCGData;

/* Input bytes remain immutable and alive until the returned image is released. */
BunImageStatus bun_coregraphics_open(const uint8_t* bytes, size_t len, uint64_t max_pixels,
    BunCGImage** out_image, uint32_t* out_width, uint32_t* out_height) BUN_IMAGE_NOEXCEPT;
void bun_coregraphics_image_release(BunCGImage* image) BUN_IMAGE_NOEXCEPT;
BunImageStatus bun_coregraphics_render(BunCGImage* image, uint8_t* out, size_t out_len) BUN_IMAGE_NOEXCEPT;
BunImageStatus bun_coregraphics_encode(const uint8_t* rgba, size_t rgba_len,
    uint32_t width, uint32_t height, BunImageFormat format, uint8_t quality,
    const BunCGData** out_data) BUN_IMAGE_NOEXCEPT;

/* Data owns the returned immutable bytes until data_release. */
const uint8_t* bun_coregraphics_data_bytes(const BunCGData* data, size_t* out_len) BUN_IMAGE_NOEXCEPT;
void bun_coregraphics_data_release(const BunCGData* data) BUN_IMAGE_NOEXCEPT;

BunImageStatus bun_coregraphics_scale(const uint8_t* src, size_t src_len,
    uint32_t src_width, uint32_t src_height, uint8_t* dst, size_t dst_len,
    uint32_t dst_width, uint32_t dst_height) BUN_IMAGE_NOEXCEPT;
BunImageStatus bun_coregraphics_rotate90(const uint8_t* src, size_t src_len,
    uint32_t width, uint32_t height, uint8_t* dst, size_t dst_len, uint8_t quarters) BUN_IMAGE_NOEXCEPT;
BunImageStatus bun_coregraphics_reflect(const uint8_t* src, size_t src_len,
    uint32_t width, uint32_t height, uint8_t* dst, size_t dst_len, uint8_t horizontal) BUN_IMAGE_NOEXCEPT;

/* No image on the clipboard returns null with an OK status. */
BunImageStatus bun_coregraphics_clipboard(const BunCGData** out_data) BUN_IMAGE_NOEXCEPT;
BunImageStatus bun_coregraphics_clipboard_change_count(int64_t* out_count) BUN_IMAGE_NOEXCEPT;

struct IPropertyBag2;
struct IStream;
int32_t bun_wic_propbag_write_f32(struct IPropertyBag2* properties,
    const uint16_t* name, float value) BUN_IMAGE_NOEXCEPT;
int32_t bun_wic_propbag_write_u8(struct IPropertyBag2* properties,
    const uint16_t* name, uint8_t value) BUN_IMAGE_NOEXCEPT;
int32_t bun_wic_stream_size(struct IStream* stream, uint64_t* out_size) BUN_IMAGE_NOEXCEPT;

#ifdef __cplusplus
}
#endif
#undef BUN_IMAGE_NOEXCEPT
