#include "BunImage.h"
#include "ImageSize.h"

#if defined(__APPLE__)

#include <Accelerate/Accelerate.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <algorithm>
#include <dlfcn.h>
#include <limits>
#include <utility>

namespace {

constexpr CGBitmapInfo rgbaFormat = static_cast<CGBitmapInfo>(kCGImageAlphaLast | kCGBitmapByteOrder32Big);

#define BUN_IMAGE_FRAMEWORK_FUNCTIONS(F) \
    F(objc_getClass) \
    F(sel_registerName) \
    F(objc_msgSend) \
    F(CFRetain) \
    F(CFRelease) \
    F(CFDataCreateWithBytesNoCopy) \
    F(CFDataCreateMutable) \
    F(CFDataGetLength) \
    F(CFDataGetBytePtr) \
    F(CFStringCreateWithCString) \
    F(CFNumberCreate) \
    F(CFDictionaryCreate) \
    F(CGColorSpaceCreateDeviceRGB) \
    F(CGImageCreate) \
    F(CGImageGetWidth) \
    F(CGImageGetHeight) \
    F(CGDataProviderCreateWithData) \
    F(CGImageSourceCreateWithData) \
    F(CGImageSourceCreateImageAtIndex) \
    F(CGImageDestinationCreateWithData) \
    F(CGImageDestinationAddImage) \
    F(CGImageDestinationFinalize) \
    F(vImageBuffer_InitWithCGImage) \
    F(vImageScale_ARGB8888) \
    F(vImageRotate90_ARGB8888) \
    F(vImageHorizontalReflect_ARGB8888) \
    F(vImageVerticalReflect_ARGB8888)

#define BUN_IMAGE_FRAMEWORK_DATA(F) \
    F(kCFAllocatorNull) \
    F(kCGImageDestinationLossyCompressionQuality) \
    F(kCFTypeDictionaryKeyCallBacks) \
    F(kCFTypeDictionaryValueCallBacks)

struct Framework {
#define FUNCTION(name) decltype(&::name) name;
    BUN_IMAGE_FRAMEWORK_FUNCTIONS(FUNCTION)
#undef FUNCTION
#define DATA(name) decltype(&::name) name;
    BUN_IMAGE_FRAMEWORK_DATA(DATA)
#undef DATA
    void* (*pushPool)();
    void (*popPool)(void*);
};

const Framework* load()
{
    static const Framework* table = []() -> const Framework* {
        static Framework framework {};
        void* libraries[] = {
            dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY | RTLD_LOCAL),
            dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY | RTLD_LOCAL),
            dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL),
            dlopen("/System/Library/Frameworks/ImageIO.framework/ImageIO", RTLD_LAZY | RTLD_LOCAL),
            dlopen("/System/Library/Frameworks/Accelerate.framework/Accelerate", RTLD_LAZY | RTLD_LOCAL),
        };
        const auto close = [&] {
            for (auto library : libraries)
                if (library) dlclose(library);
        };
        for (auto library : libraries) {
            if (!library) {
                close();
                return nullptr;
            }
        }
        const auto symbol = [&](const char* name) -> void* {
            for (auto library : libraries)
                if (auto value = dlsym(library, name)) return value;
            return nullptr;
        };
#define RESOLVE(name) \
    framework.name = reinterpret_cast<decltype(framework.name)>(symbol(#name)); \
    if (!framework.name) { \
        close(); \
        return nullptr; \
    }
        BUN_IMAGE_FRAMEWORK_FUNCTIONS(RESOLVE)
        BUN_IMAGE_FRAMEWORK_DATA(RESOLVE)
#undef RESOLVE
        framework.pushPool = reinterpret_cast<decltype(framework.pushPool)>(symbol("objc_autoreleasePoolPush"));
        framework.popPool = reinterpret_cast<decltype(framework.popPool)>(symbol("objc_autoreleasePoolPop"));
        if (!framework.pushPool || !framework.popPool) {
            close();
            return nullptr;
        }
        return &framework;
    }();
    return table;
}

#undef BUN_IMAGE_FRAMEWORK_FUNCTIONS
#undef BUN_IMAGE_FRAMEWORK_DATA

// Image workers have no enclosing Objective-C autorelease pool.
struct Pool {
    const Framework* framework;
    void* pool;
    explicit Pool(const Framework* framework)
        : framework(framework)
        , pool(framework->pushPool())
    {
    }
    ~Pool() { framework->popPool(pool); }
    Pool(const Pool&) = delete;
};

template<typename T>
class Owner {
    const Framework* framework;
    T value;

public:
    Owner(const Framework* framework, T value)
        : framework(framework)
        , value(value)
    {
    }
    ~Owner()
    {
        if (value) framework->CFRelease(value);
    }
    Owner(const Owner&) = delete;
    T get() const { return value; }
    T take() { return std::exchange(value, nullptr); }
    explicit operator bool() const { return value != nullptr; }
};

template<class R, class... Args>
R message(const Framework* framework, id receiver, const char* selector, Args... args)
{
    return reinterpret_cast<R (*)(id, SEL, Args...)>(framework->objc_msgSend)(
        receiver, framework->sel_registerName(selector), args...);
}

id generalPasteboard(const Framework* framework)
{
    static void* appkit = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY | RTLD_LOCAL);
    if (!appkit) return nullptr;
    auto cls = framework->objc_getClass("NSPasteboard");
    return cls ? message<id>(framework, reinterpret_cast<id>(cls), "generalPasteboard") : nullptr;
}

BunImageStatus imageStatus(vImage_Error status, BunImageStatus failure)
{
    if (status == kvImageNoError) return BUN_IMAGE_OK;
    if (status == kvImageMemoryAllocationError) return BUN_IMAGE_OUT_OF_MEMORY;
    return failure;
}

bool buffers(const uint8_t* src, size_t srcLength, uint32_t srcWidth, uint32_t srcHeight,
    uint8_t* dst, size_t dstLength, uint32_t dstWidth, uint32_t dstHeight)
{
    size_t srcRequired, dstRequired;
    return bun_image::rgbaByteLength(srcWidth, srcHeight, srcRequired)
        && bun_image::rgbaByteLength(dstWidth, dstHeight, dstRequired)
        && bun_image::validBuffers(src, srcLength, srcRequired, dst, dstLength, dstRequired);
}

}

extern "C" BunImageStatus bun_coregraphics_open(const uint8_t* bytes, size_t len, uint64_t maxPixels,
    BunCGImage** outImage, uint32_t* outWidth, uint32_t* outHeight) noexcept
{
    if (!bytes || !len || len > static_cast<size_t>(std::numeric_limits<CFIndex>::max()))
        return BUN_IMAGE_DECODE_FAILED;
    auto framework = load();
    if (!framework) return BUN_IMAGE_UNAVAILABLE;
    Pool pool(framework);
    Owner data(framework, framework->CFDataCreateWithBytesNoCopy(nullptr, bytes, static_cast<CFIndex>(len), *framework->kCFAllocatorNull));
    if (!data) return BUN_IMAGE_OUT_OF_MEMORY;
    Owner source(framework, framework->CGImageSourceCreateWithData(data.get(), nullptr));
    if (!source) return BUN_IMAGE_DECODE_FAILED;
    Owner image(framework, framework->CGImageSourceCreateImageAtIndex(source.get(), 0, nullptr));
    if (!image) return BUN_IMAGE_DECODE_FAILED;
    const auto width = framework->CGImageGetWidth(image.get());
    const auto height = framework->CGImageGetHeight(image.get());
    if (!width || !height) return BUN_IMAGE_DECODE_FAILED;
    if (width > maxPixels / height) return BUN_IMAGE_TOO_MANY_PIXELS;
    size_t size;
    if (width > UINT32_MAX || height > UINT32_MAX || !bun_image::rgbaByteLength(width, height, size))
        return BUN_IMAGE_INVALID_INPUT;
    *outWidth = static_cast<uint32_t>(width);
    *outHeight = static_cast<uint32_t>(height);
    *outImage = image.take();
    return BUN_IMAGE_OK;
}

extern "C" void bun_coregraphics_image_release(BunCGImage* image) noexcept
{
    if (!image) return;
    auto framework = load();
    Pool pool(framework);
    framework->CFRelease(image);
}

extern "C" BunImageStatus bun_coregraphics_render(BunCGImage* image, uint8_t* out, size_t outLength) noexcept
{
    auto framework = load();
    if (!framework) return BUN_IMAGE_UNAVAILABLE;
    if (!image || !out) return BUN_IMAGE_INVALID_INPUT;
    Pool pool(framework);
    const auto width = framework->CGImageGetWidth(image);
    const auto height = framework->CGImageGetHeight(image);
    size_t size;
    if (!bun_image::rgbaByteLength(width, height, size) || size > outLength)
        return BUN_IMAGE_INVALID_INPUT;
    Owner colorSpace(framework, framework->CGColorSpaceCreateDeviceRGB());
    if (!colorSpace) return BUN_IMAGE_OUT_OF_MEMORY;
    vImage_Buffer buffer { out, height, width, width * 4 };
    // Straight alpha preserves RGB values without premultiplication loss.
    vImage_CGImageFormat format { 8, 32, colorSpace.get(), rgbaFormat, 0, nullptr, kCGRenderingIntentDefault };
    return imageStatus(framework->vImageBuffer_InitWithCGImage(&buffer, &format, nullptr, image, kvImageNoAllocate), BUN_IMAGE_DECODE_FAILED);
}

extern "C" BunImageStatus bun_coregraphics_encode(const uint8_t* rgba, size_t rgbaLength,
    uint32_t width, uint32_t height, uint8_t format, uint8_t quality, const BunCGData** outData) noexcept
{
    size_t size;
    if (!rgba || !bun_image::rgbaByteLength(width, height, size) || size > rgbaLength)
        return BUN_IMAGE_INVALID_INPUT;
    const char* uti;
    switch (format) {
    case BUN_IMAGE_FORMAT_HEIC: uti = "public.heic"; break;
    case BUN_IMAGE_FORMAT_AVIF: uti = "public.avif"; break;
    default: return BUN_IMAGE_UNAVAILABLE;
    }
    auto framework = load();
    if (!framework) return BUN_IMAGE_UNAVAILABLE;
    Pool pool(framework);
    Owner colorSpace(framework, framework->CGColorSpaceCreateDeviceRGB());
    if (!colorSpace) return BUN_IMAGE_OUT_OF_MEMORY;
    Owner provider(framework, framework->CGDataProviderCreateWithData(nullptr, rgba, size, nullptr));
    if (!provider) return BUN_IMAGE_OUT_OF_MEMORY;
    Owner image(framework, framework->CGImageCreate(width, height, 8, 32, static_cast<size_t>(width) * 4,
        colorSpace.get(), rgbaFormat, provider.get(), nullptr, false, kCGRenderingIntentDefault));
    if (!image) return BUN_IMAGE_ENCODE_FAILED;
    Owner type(framework, framework->CFStringCreateWithCString(nullptr, uti, kCFStringEncodingUTF8));
    if (!type) return BUN_IMAGE_OUT_OF_MEMORY;
    Owner sink(framework, framework->CFDataCreateMutable(nullptr, 0));
    if (!sink) return BUN_IMAGE_OUT_OF_MEMORY;
    Owner destination(framework, framework->CGImageDestinationCreateWithData(sink.get(), type.get(), 1, nullptr));
    if (!destination) return BUN_IMAGE_UNAVAILABLE;
    const double compression = std::clamp(static_cast<double>(quality), 1.0, 100.0) / 100.0;
    Owner number(framework, framework->CFNumberCreate(nullptr, kCFNumberDoubleType, &compression));
    if (!number) return BUN_IMAGE_OUT_OF_MEMORY;
    const void* key = *framework->kCGImageDestinationLossyCompressionQuality;
    const void* value = number.get();
    Owner properties(framework, framework->CFDictionaryCreate(nullptr, &key, &value, 1,
        framework->kCFTypeDictionaryKeyCallBacks, framework->kCFTypeDictionaryValueCallBacks));
    if (!properties) return BUN_IMAGE_OUT_OF_MEMORY;
    framework->CGImageDestinationAddImage(destination.get(), image.get(), properties.get());
    if (!framework->CGImageDestinationFinalize(destination.get())) return BUN_IMAGE_ENCODE_FAILED;
    if (framework->CFDataGetLength(sink.get()) <= 0) return BUN_IMAGE_ENCODE_FAILED;
    *outData = sink.take();
    return BUN_IMAGE_OK;
}

extern "C" const uint8_t* bun_coregraphics_data_bytes(const BunCGData* data, size_t* outLength) noexcept
{
    auto framework = load();
    *outLength = static_cast<size_t>(framework->CFDataGetLength(data));
    return framework->CFDataGetBytePtr(data);
}

extern "C" void bun_coregraphics_data_release(const BunCGData* data) noexcept
{
    if (!data) return;
    auto framework = load();
    Pool pool(framework);
    framework->CFRelease(data);
}

extern "C" BunImageStatus bun_coregraphics_scale(const uint8_t* src, size_t srcLength,
    uint32_t srcWidth, uint32_t srcHeight, uint8_t* dst, size_t dstLength, uint32_t dstWidth, uint32_t dstHeight) noexcept
{
    if (!buffers(src, srcLength, srcWidth, srcHeight, dst, dstLength, dstWidth, dstHeight)) return BUN_IMAGE_INVALID_INPUT;
    auto framework = load();
    if (!framework) return BUN_IMAGE_UNAVAILABLE;
    Pool pool(framework);
    vImage_Buffer in { const_cast<uint8_t*>(src), srcHeight, srcWidth, static_cast<size_t>(srcWidth) * 4 };
    vImage_Buffer out { dst, dstHeight, dstWidth, static_cast<size_t>(dstWidth) * 4 };
    return imageStatus(framework->vImageScale_ARGB8888(&in, &out, nullptr, kvImageEdgeExtend | kvImageDoNotTile), BUN_IMAGE_UNAVAILABLE);
}

extern "C" BunImageStatus bun_coregraphics_rotate90(const uint8_t* src, size_t srcLength,
    uint32_t width, uint32_t height, uint8_t* dst, size_t dstLength, uint8_t quarters) noexcept
{
    const uint32_t dstWidth = quarters & 1 ? height : width;
    const uint32_t dstHeight = quarters & 1 ? width : height;
    if (quarters > 3 || !buffers(src, srcLength, width, height, dst, dstLength, dstWidth, dstHeight)) return BUN_IMAGE_INVALID_INPUT;
    auto framework = load();
    if (!framework) return BUN_IMAGE_UNAVAILABLE;
    Pool pool(framework);
    // vImage uses counterclockwise quarter turns.
    static constexpr uint8_t turns[] = { 0, 3, 2, 1 };
    static constexpr uint8_t background[] = { 0, 0, 0, 0 };
    vImage_Buffer in { const_cast<uint8_t*>(src), height, width, static_cast<size_t>(width) * 4 };
    vImage_Buffer out { dst, dstHeight, dstWidth, static_cast<size_t>(dstWidth) * 4 };
    return imageStatus(framework->vImageRotate90_ARGB8888(&in, &out, turns[quarters], background, kvImageDoNotTile), BUN_IMAGE_UNAVAILABLE);
}

extern "C" BunImageStatus bun_coregraphics_reflect(const uint8_t* src, size_t srcLength,
    uint32_t width, uint32_t height, uint8_t* dst, size_t dstLength, uint8_t horizontal) noexcept
{
    if (horizontal > 1 || !buffers(src, srcLength, width, height, dst, dstLength, width, height)) return BUN_IMAGE_INVALID_INPUT;
    auto framework = load();
    if (!framework) return BUN_IMAGE_UNAVAILABLE;
    Pool pool(framework);
    vImage_Buffer in { const_cast<uint8_t*>(src), height, width, static_cast<size_t>(width) * 4 };
    vImage_Buffer out { dst, height, width, static_cast<size_t>(width) * 4 };
    auto reflect = horizontal ? framework->vImageHorizontalReflect_ARGB8888 : framework->vImageVerticalReflect_ARGB8888;
    return imageStatus(reflect(&in, &out, kvImageDoNotTile), BUN_IMAGE_UNAVAILABLE);
}

extern "C" BunImageStatus bun_coregraphics_clipboard(const BunCGData** outData) noexcept
{
    auto framework = load();
    if (!framework) return BUN_IMAGE_UNAVAILABLE;
    Pool pool(framework);
    auto pasteboard = generalPasteboard(framework);
    if (!pasteboard) return BUN_IMAGE_UNAVAILABLE;
    // Prefer compact native formats before the system's uncompressed TIFF fallback.
    static constexpr const char* types[] = {
        "public.png", "public.heic", "public.heif", "public.avif", "public.jpeg",
        "org.webmproject.webp", "com.compuserve.gif", "com.microsoft.bmp", "public.tiff",
    };
    for (auto type : types) {
        Owner string(framework, framework->CFStringCreateWithCString(nullptr, type, kCFStringEncodingUTF8));
        if (!string) return BUN_IMAGE_OUT_OF_MEMORY;
        auto data = reinterpret_cast<CFDataRef>(message<id>(framework, pasteboard, "dataForType:", string.get()));
        if (!data || framework->CFDataGetLength(data) <= 0) continue;
        framework->CFRetain(data);
        *outData = data;
        return BUN_IMAGE_OK;
    }
    *outData = nullptr;
    return BUN_IMAGE_OK;
}

extern "C" BunImageStatus bun_coregraphics_clipboard_change_count(int64_t* outCount) noexcept
{
    auto framework = load();
    if (!framework) return BUN_IMAGE_UNAVAILABLE;
    Pool pool(framework);
    auto pasteboard = generalPasteboard(framework);
    if (!pasteboard) return BUN_IMAGE_UNAVAILABLE;
    *outCount = message<long>(framework, pasteboard, "changeCount");
    return BUN_IMAGE_OK;
}

#endif
