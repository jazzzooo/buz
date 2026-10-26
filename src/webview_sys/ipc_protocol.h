#pragma once

// Wire protocol between the Bun process (parent, JS thread, usockets) and
// the WebView host process (child, CFRunLoopRun on thread 0). Length-prefixed
// frames over a SOCK_STREAM socketpair. No JSON, no alignment padding.
//
// Parent death → socket EOF → child's read() returns 0 → CFRunLoopStop.

#include <cstdint>
#include <cstring>
#include <span>
#include <type_traits>
#include <wtf/Forward.h>
#include <expected>
#include <wtf/Platform.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>
#include <wtf/text/CString.h>
#if OS(DARWIN)
#include <wtf/unix/UnixFileDescriptor.h>
#endif

typedef struct __CFFileDescriptor* CFFileDescriptorRef;

namespace Bun::WebViewProto {

#pragma pack(push, 1)

struct Frame {
    uint32_t len; // payload bytes following this 9-byte header
    uint32_t viewId; // parent-assigned; child routes by it, echoes in reply.
                     // Reply type → slot on JSWebView. No req_id map.
    uint8_t op;
    // uint8_t payload[len] follows
};

static_assert(sizeof(Frame) == 9);

// Cap at uint30 max. evaluate() scripts can be arbitrarily large; this just
// catches the 0xFFFFFFFF corruption case (top two bits set) before unbounded
// rx growth + livelock on a never-satisfiable partial-payload check.
constexpr uint32_t kMaxFrameLen = (1u << 30) - 1;

#pragma pack(pop)

// Parent → child. viewId is in the frame header.
enum class Op : uint8_t {
    Create = 1, // u32 w, u32 h, u8 dataStoreKind, [u32 dirLen, dir bytes]
    Navigate = 2, // u32 urlLen, url bytes
    Evaluate = 3, // u32 scriptLen, script bytes
    Screenshot = 4, // u8 format (0=png 1=jpeg 2=webp), u8 quality (0-100, ignored for png)
    Close = 5, // (empty)
    Resize = 6, // u32 w, u32 h
    GoBack = 7, // (empty)
    GoForward = 8, // (empty)
    Reload = 9, // (empty)

    // Native input with proper WebKit completion barriers.
    // Click: NSEvent mouseDown/Up + _doAfterProcessingAllPendingMouseEvents:
    // Type:  _executeEditCommand("InsertText") — sendWithAsyncReply
    // Press: editing command with completion, or keyDown fallback for
    //        Escape/chord keys (no completion; WebKit exposes no keyboard
    //        equivalent of the mouse barrier).
    Click = 10, // ClickPayload
    Type = 11, // str text
    Press = 12, // PressPayload + [str char iff VirtualKey::Character]
    Scroll = 13, // ScrollPayload

    // click(selector) — page-side rAF-polled actionability check via
    // callAsyncJavaScript:, then native click at the resolved coords.
    ClickSelector = 14, // ClickSelectorPayload + str selector

    // scrollTo(selector) — page-side scrollIntoView via callAsyncJavaScript:
    // after waiting for the element to exist. No native wheel; scroll event
    // fires (isTrusted:true — browser-driven), scrollY updates,
    // IntersectionObserver triggers.
    ScrollTo = 15, // ScrollToPayload + str selector
};

// Mouse button: 0=left, 1=right, 2=middle.
// Modifier bits (parent encoding, expanded to NSEventModifierFlags in child):
enum : uint8_t {
    ModShift = 1 << 0,
    ModCtrl = 1 << 1,
    ModAlt = 1 << 2,
    ModMeta = 1 << 3,
};

// --- Payload structs -------------------------------------------------------
// Fixed-size heads; variable-length strings (u32 len + utf8) follow where
// noted. Both sides include this header so encode/decode stay in lockstep.
// No padding — pragma pack(1) already in effect above for Frame.

#pragma pack(push, 1)

struct CreatePayload {
    uint32_t width;
    uint32_t height;
    uint8_t dataStoreKind; // DataStoreKind; str persistDir follows iff Persistent
};

struct ClickPayload {
    float x; // viewport coords, y-down
    float y;
    uint8_t button;
    uint8_t modifiers;
    uint8_t clickCount;
};

struct ResizePayload {
    uint32_t width;
    uint32_t height;
};

struct PressPayload {
    uint8_t virtualKey; // VirtualKey; str character follows iff Character
    uint8_t modifiers;
};

struct ScrollPayload {
    float deltaX;
    float deltaY;
};

struct ClickSelectorPayload {
    uint32_t timeout; // ms; page-time (performance.now), pauses with debugger
    uint8_t button;
    uint8_t modifiers;
    uint8_t clickCount;
    // str selector follows
};

struct ScrollToPayload {
    uint32_t timeout;
    uint8_t block; // 0=start 1=center 2=end 3=nearest
    // str selector follows
};

#pragma pack(pop)

static_assert(sizeof(CreatePayload) == 9);
static_assert(sizeof(ClickPayload) == 11);
static_assert(sizeof(ResizePayload) == 8);
static_assert(sizeof(PressPayload) == 2);
static_assert(sizeof(ScrollPayload) == 8);
static_assert(sizeof(ClickSelectorPayload) == 7);
static_assert(sizeof(ScrollToPayload) == 5);

enum class PayloadError : uint8_t {
    TooLarge,
    OutOfMemory,
};

using Payload = WTF::Vector<uint8_t, 64>;
using EncodedPayload = std::expected<Payload, PayloadError>;

template<size_t capacity>
std::expected<void, PayloadError> appendString(WTF::Vector<uint8_t, capacity>& payload, const WTF::String& value)
{
    constexpr size_t prefixSize = sizeof(uint32_t);
    if (payload.size() > kMaxFrameLen - prefixSize
        || value.length() > kMaxFrameLen - prefixSize - payload.size())
        return WTF::makeUnexpected(PayloadError::TooLarge);
    auto utf8 = value.tryGetUTF8();
    if (!utf8) return WTF::makeUnexpected(PayloadError::OutOfMemory);
    if (utf8->length() > kMaxFrameLen - prefixSize - payload.size())
        return WTF::makeUnexpected(PayloadError::TooLarge);
    size_t offset = payload.size();
    uint32_t length = static_cast<uint32_t>(utf8->length());
    if (!payload.tryGrow(offset + prefixSize + length))
        return WTF::makeUnexpected(PayloadError::OutOfMemory);
    memcpy(payload.mutableSpan().data() + offset, &length, prefixSize);
    if (length)
        memcpy(payload.mutableSpan().data() + offset + prefixSize, utf8->data(), length);
    return {};
}

template<typename Head>
EncodedPayload encode(const Head& head, const WTF::String& tail = {})
{
    static_assert(std::is_trivially_copyable_v<Head>);
    static_assert(sizeof(Head) <= kMaxFrameLen);
    Payload out;
    if (!out.tryGrow(sizeof(Head))) return WTF::makeUnexpected(PayloadError::OutOfMemory);
    memcpy(out.mutableSpan().data(), &head, sizeof(Head));
    if (!tail.isNull()) {
        auto result = appendString(out, tail);
        if (!result) return WTF::makeUnexpected(result.error());
    }
    return out;
}

// String-only payload (Navigate, Evaluate, Type) — no head struct.
inline EncodedPayload encodeStr(const WTF::String& s)
{
    Payload out;
    auto result = appendString(out, s);
    if (!result) return WTF::makeUnexpected(result.error());
    return out;
}

// Press() key tag. Order doesn't matter across the wire — both sides
// include this header. Parent maps JS string name → tag; child maps tag →
// editing command (with completion) or HID keyCode (keyDown fallback).
enum class VirtualKey : uint8_t {
    Character = 0, // payload has a trailing str (single char, e.g. Cmd+A)
    Enter,
    Tab,
    Space,
    Backspace,
    Delete,
    Escape,
    ArrowLeft,
    ArrowRight,
    ArrowUp,
    ArrowDown,
    Home,
    End,
    PageUp,
    PageDown,
};

// Child → parent. Reply type determines the WriteBarrier slot on JSWebView:
// NavDone/NavFailed → m_pendingNavigate, EvalDone/EvalFailed → m_pendingEval,
// ScreenshotDone/Failed → m_pendingScreenshot, Ack/Error → m_pendingMisc.
enum class Reply : uint8_t {
    NavDone = 2, // u32 urlLen, url bytes, u32 titleLen, title bytes
    NavFailed = 3, // u32 errLen, err bytes
    EvalDone = 4, // u32 resultLen, result bytes
    EvalFailed = 5, // u32 errLen, err bytes
    ScreenshotDone = 6, // u32 byteLen; one SCM_RIGHTS descriptor, in reply order
    ScreenshotFailed = 7, // u32 errLen, err bytes
    Ack = 8, // no payload — Create/Close/Resize/Go*/Reload
    Error = 9, // u32 errLen, err bytes

    // Unsolicited — fires the onNavigated/onNavigationFailed callback.
    // Same viewId in header; these arrive BEFORE the corresponding
    // NavDone/NavFailed reply so the callback fires before `await` resumes.
    NavEvent = 10, // u32 urlLen, url, u32 titleLen, title
    NavFailEvent = 11, // u32 errLen, err

    // Unsolicited — fires the console callback or forwards to the global
    // console. A user-script wrap of console.{log,warn,...} posts via
    // WKScriptMessageHandler; the delegate packs and ships this event.
    // Payload: str type + u32 argCount + (str arg)*, where each arg is
    // the page-side JSON.stringify of the console argument.
    ConsoleEvent = 12,
};

enum class DataStoreKind : uint8_t {
    Ephemeral = 0,
    Persistent = 1,
};

struct Reader {
    const uint8_t* p;
    const uint8_t* end;
    bool valid { true };

    size_t remaining() const { return p == end ? 0 : static_cast<size_t>(end - p); }
    bool finished() const { return valid && p == end; }

    template<typename T>
    T scalar()
    {
        static_assert(std::is_trivially_copyable_v<T>);
        T v {};
        if (auto* data = bytes(sizeof(T)))
            __builtin_memcpy(&v, data, sizeof(T));
        return v;
    }
    uint32_t u32() { return scalar<uint32_t>(); }
    uint16_t u16() { return scalar<uint16_t>(); }
    float f32() { return scalar<float>(); }
    uint8_t u8() { return scalar<uint8_t>(); }

    const uint8_t* bytes(size_t n)
    {
        if (!valid || n > remaining()) [[unlikely]] {
            valid = false;
            p = end;
            return nullptr;
        }
        auto* r = p;
        if (n) p += n;
        return r;
    }

    void skipString() { bytes(u32()); }

    // u32 length + UTF-8 bytes → WTF::String.
    WTF::String str()
    {
        uint32_t n = u32();
        auto* b = bytes(n);
        if (!valid) return {};
        return WTF::String::fromUTF8(std::span<const char>(reinterpret_cast<const char*>(b), n));
    }
};

// Child-side decode for payload structs. Reader already bounds-checks;
// this reads the head out of the stream and advances past it.
template<typename Head>
Head decode(Reader& r)
{
    return r.scalar<Head>();
}

inline bool validPayload(Op op, Reader r)
{
    switch (op) {
    case Op::Create: {
        auto head = decode<CreatePayload>(r);
        if (head.dataStoreKind > static_cast<uint8_t>(DataStoreKind::Persistent)) return false;
        if (static_cast<DataStoreKind>(head.dataStoreKind) == DataStoreKind::Persistent) r.skipString();
        break;
    }
    case Op::Navigate:
    case Op::Evaluate:
    case Op::Type:
        r.skipString();
        break;
    case Op::Screenshot: {
        auto format = r.u8();
        auto quality = r.u8();
        if (format > 1 || quality > 100) return false;
        break;
    }
    case Op::Close:
    case Op::GoBack:
    case Op::GoForward:
    case Op::Reload:
        break;
    case Op::Resize:
        r.bytes(sizeof(ResizePayload));
        break;
    case Op::Click:
        r.bytes(sizeof(ClickPayload));
        break;
    case Op::Press: {
        auto head = decode<PressPayload>(r);
        if (head.virtualKey > static_cast<uint8_t>(VirtualKey::PageDown)) return false;
        if (static_cast<VirtualKey>(head.virtualKey) == VirtualKey::Character) r.skipString();
        break;
    }
    case Op::Scroll:
        r.bytes(sizeof(ScrollPayload));
        break;
    case Op::ClickSelector:
        r.bytes(sizeof(ClickSelectorPayload));
        r.skipString();
        break;
    case Op::ScrollTo:
        r.bytes(sizeof(ScrollToPayload));
        r.skipString();
        break;
    default:
        return false;
    }
    return r.finished();
}

inline bool validPayload(Reply reply, Reader r)
{
    switch (reply) {
    case Reply::NavDone:
    case Reply::NavEvent:
        r.skipString();
        r.skipString();
        break;
    case Reply::NavFailed:
    case Reply::EvalDone:
    case Reply::EvalFailed:
    case Reply::ScreenshotFailed:
    case Reply::Error:
    case Reply::NavFailEvent:
        r.skipString();
        break;
    case Reply::ScreenshotDone:
        if (!r.u32()) return false;
        break;
    case Reply::Ack:
        break;
    case Reply::ConsoleEvent: {
        r.skipString();
        uint32_t count = r.u32();
        if (count > r.remaining() / sizeof(uint32_t)) return false;
        for (uint32_t i = 0; i < count && r.valid; ++i) r.skipString();
        break;
    }
    default:
        return false;
    }
    return r.finished();
}

// Child-side writer. Decl here so WebViewHost's completion callbacks can
// call sendReply; impl in host_main.cpp (owns the CF fd).
#if OS(DARWIN)
class FrameWriter {
public:
    bool sendReply(uint32_t viewId, Reply op, const uint8_t* payload = nullptr, size_t len = 0, WTF::UnixFileDescriptor = {});
    void sendReplyStr(uint32_t viewId, Reply op, const WTF::String& s);
    void fail();
    bool failed() const { return m_failed; }

    void init(int fd, CFFileDescriptorRef cffd)
    {
        m_fd = fd;
        m_cffd = cffd;
    }
    void onWritable();

private:
    struct PendingFrame {
        WTF::Vector<uint8_t, 64> bytes;
        size_t offset { 0 };
        WTF::UnixFileDescriptor descriptor;
    };

    int m_fd = -1;
    CFFileDescriptorRef m_cffd = nullptr;
    WTF::Vector<PendingFrame> m_queue;
    bool m_failed { false };
};

FrameWriter* hostWriter();
#endif

} // namespace Bun::WebViewProto
