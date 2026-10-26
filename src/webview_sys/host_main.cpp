// WebView host subprocess entry point. Reached via cli.zig when
// BUN_INTERNAL_WEBVIEW_HOST is set. Runs CFRunLoopRun() as the real main
// loop — CF manages ignoreWakeUps correctly when it owns the loop. No
// JSC, no VM, no Zig runtime past the env check.
//
// Parent death → socket read() returns 0 → CFRunLoopStop → process exits.

#include "cmakeconfig.h"
#include <wtf/Platform.h>
#include "BunWebViewHost.h"

#if OS(DARWIN)

#include "ObjCRuntime.h"
#include "WebViewHost.h"
#include "ipc_protocol.h"

#include <CoreFoundation/CFFileDescriptor.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>
#include <stdio.h>
#include <errno.h>

#include <unordered_map>
#include <wtf/NeverDestroyed.h>

namespace Bun {
namespace WebViewProto {

// ---------------------------------------------------------------------------
// CF symbols the child needs beyond ObjCRuntime's set. Could be merged
// into ObjCRuntime, but this file is the only consumer and ObjCRuntime is
// already large. dlsym'd at hostMain entry.
// ---------------------------------------------------------------------------
static struct {
    void (*CFRunLoopRun)();
    void (*CFRunLoopStop)(CFRunLoopRef);
    CFRunLoopRef (*CFRunLoopGetCurrent)();
    void (*CFRunLoopAddSource)(CFRunLoopRef, CFRunLoopSourceRef, CFStringRef);
    CFStringRef kCFRunLoopDefaultMode;

    CFFileDescriptorRef (*CFFileDescriptorCreate)(CFAllocatorRef, int, Boolean,
        void (*)(CFFileDescriptorRef, CFOptionFlags, void*), const CFFileDescriptorContext*);
    CFRunLoopSourceRef (*CFFileDescriptorCreateRunLoopSource)(CFAllocatorRef, CFFileDescriptorRef, CFIndex);
    void (*CFFileDescriptorEnableCallBacks)(CFFileDescriptorRef, CFOptionFlags);
} cf;

static bool loadHostCF()
{
    void* h = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY | RTLD_LOCAL);
    if (!h) return false;
#define S(name)                                                     \
    cf.name = reinterpret_cast<decltype(cf.name)>(dlsym(h, #name)); \
    if (!cf.name) return false
    S(CFRunLoopRun);
    S(CFRunLoopStop);
    S(CFRunLoopGetCurrent);
    S(CFRunLoopAddSource);
    S(CFFileDescriptorCreate);
    S(CFFileDescriptorCreateRunLoopSource);
    S(CFFileDescriptorEnableCallBacks);
#undef S
    auto* mode = reinterpret_cast<CFStringRef*>(dlsym(h, "kCFRunLoopDefaultMode"));
    if (!mode) return false;
    cf.kCFRunLoopDefaultMode = *mode;
    return true;
}

void FrameWriter::fail()
{
    if (m_failed) return;
    m_failed = true;
    m_queue.clear();
    shutdown(m_fd, SHUT_RDWR);
    cf.CFRunLoopStop(cf.CFRunLoopGetCurrent());
}

bool FrameWriter::sendReply(uint32_t viewId, Reply op, const uint8_t* payload, size_t len, WTF::UnixFileDescriptor descriptor)
{
    if (m_failed) return false;
    if (len > kMaxFrameLen || (len && !payload)
        || (static_cast<bool>(descriptor) != (op == Reply::ScreenshotDone))) {
        fail();
        return false;
    }
    Frame h = { static_cast<uint32_t>(len), viewId, static_cast<uint8_t>(op) };
    PendingFrame frame;
    frame.descriptor = WTF::move(descriptor);
    if (!frame.bytes.tryGrow(sizeof(h) + len)) {
        fail();
        return false;
    }
    memcpy(frame.bytes.mutableSpan().data(), &h, sizeof(h));
    if (len) memcpy(frame.bytes.mutableSpan().data() + sizeof(h), payload, len);
    if (!m_queue.tryAppend(WTF::move(frame))) {
        fail();
        return false;
    }
    onWritable();
    return !m_failed;
}

void FrameWriter::sendReplyStr(uint32_t viewId, Reply op, const WTF::String& s)
{
    WTF::Vector<uint8_t, 256> payload;
    if (!appendString(payload, s)) {
        fail();
        return;
    }
    sendReply(viewId, op, payload.span().data(), payload.size());
}

void FrameWriter::onWritable()
{
    if (m_failed) return;
    while (!m_queue.isEmpty()) {
        auto& frame = m_queue[0];
        ssize_t w;
        if (frame.descriptor) {
            // A single carrier byte makes descriptor delivery all-or-nothing.
            iovec iov { frame.bytes.mutableSpan().data(), 1 };
            alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))] {};
            msghdr message {};
            message.msg_iov = &iov;
            message.msg_iovlen = 1;
            message.msg_control = control;
            message.msg_controllen = sizeof(control);
            auto* header = CMSG_FIRSTHDR(&message);
            header->cmsg_level = SOL_SOCKET;
            header->cmsg_type = SCM_RIGHTS;
            header->cmsg_len = CMSG_LEN(sizeof(int));
            int descriptor = frame.descriptor.value();
            memcpy(CMSG_DATA(header), &descriptor, sizeof(descriptor));
            w = ::sendmsg(m_fd, &message, 0);
            if (w > 0) frame.descriptor = {};
        } else {
            w = ::write(m_fd, frame.bytes.span().data() + frame.offset, frame.bytes.size() - frame.offset);
        }
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                cf.CFFileDescriptorEnableCallBacks(m_cffd, kCFFileDescriptorWriteCallBack);
            } else fail();
            return;
        }
        if (w == 0) {
            fail();
            return;
        }
        frame.offset += static_cast<size_t>(w);
        if (frame.offset == frame.bytes.size()) m_queue.removeAt(0);
    }
}

// ---------------------------------------------------------------------------
// Host state: all views by id, the socket, the frame writer.
// Single-threaded — everything runs inside CFRunLoop callbacks.
// ---------------------------------------------------------------------------
struct Host {
    int fd = -1;
    CFFileDescriptorRef cffd = nullptr;
    FrameWriter writer;

    std::unordered_map<uint32_t, Ref<WebViewHost>> views;

    // CFFileDescriptor delivers one callback then disarms; read until EAGAIN,
    // then re-enable. Incomplete frame at buffer tail stays until more bytes.
    WTF::Vector<uint8_t> rx;

    void onReadable();
    bool dispatchFrames();
    void dispatch(uint32_t viewId, Op op, Reader payload);

    // Op → failure reply type. Lets "invalid viewId" reject the correct
    // parent-side slot (Navigate → m_pendingNavigate, etc.) instead of
    // always Reply::Error which is misc-only. Everything past Screenshot
    // is a misc op.
    static constexpr Reply failureFor(Op op)
    {
        switch (op) {
        case Op::Navigate:
            return Reply::NavFailed;
        case Op::Evaluate:
            return Reply::EvalFailed;
        case Op::Screenshot:
            return Reply::ScreenshotFailed;
        default:
            return Reply::Error;
        }
    }

    WebViewHost* view(uint32_t viewId, Op op)
    {
        auto it = views.find(viewId);
        if (it == views.end()) {
            writer.sendReplyStr(viewId, failureFor(op), "invalid viewId"_s);
            return nullptr;
        }
        return it->second.ptr();
    }
};

// Lazy construct — a file-scope `static Host g_host;` would run
// unordered_map/Vector constructors at image-load in the PARENT process
// (same binary, the code is linked in even though only the child calls
// hostMain). LazyNeverDestroyed defers to first .construct(), which is
// in hostMain() on the child's thread 0.
static LazyNeverDestroyed<Host> g_host;
FrameWriter* hostWriter() { return &g_host->writer; }

void Host::onReadable()
{
    if (writer.failed()) return;
    for (;;) {
        size_t was = rx.size();
        if (was > kMaxFrameLen + sizeof(Frame) || !rx.tryGrow(was + 4096)) {
            writer.fail();
            views.clear();
            return;
        }
        ssize_t n = ::read(fd, rx.mutableSpan().data() + was, 4096);
        if (n > 0) {
            rx.shrink(was + static_cast<size_t>(n));
            if (!dispatchFrames()) {
                writer.fail();
                views.clear();
                return;
            }
            continue;
        }
        rx.shrink(was);
        if (n == 0) {
            writer.fail();
            views.clear();
            return;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        writer.fail();
        views.clear();
        return;
    }

    cf.CFFileDescriptorEnableCallBacks(cffd, kCFFileDescriptorReadCallBack);
}

bool Host::dispatchFrames()
{
    size_t off = 0;
    const uint8_t* base = rx.span().data();
    while (rx.size() - off >= sizeof(Frame)) {
        Frame h;
        memcpy(&h, base + off, sizeof(h));
        if (h.len > kMaxFrameLen) [[unlikely]] {
            return false;
        }
        if (rx.size() - off < sizeof(Frame) + h.len) break; // partial payload
        Reader r { base + off + sizeof(Frame), base + off + sizeof(Frame) + h.len };
        if (!validPayload(static_cast<Op>(h.op), r)) return false;
        dispatch(h.viewId, static_cast<Op>(h.op), r);
        if (writer.failed()) return false;
        off += sizeof(Frame) + h.len;
    }
    if (off) rx.removeAt(0, off);

    return true;
}

void Host::dispatch(uint32_t viewId, Op op, Reader r)
{
    ObjCRuntime::ARPool pool;
    switch (op) {
    case Op::Create: {
        auto p = decode<CreatePayload>(r);
        WTF::String persistDir;
        if (static_cast<DataStoreKind>(p.dataStoreKind) == DataStoreKind::Persistent)
            persistDir = r.str();
        views.emplace(viewId, WebViewHost::createForIPC(viewId, p.width, p.height, persistDir));
        // No Ack for Create — parent doesn't await it (fire-and-forget).
        return;
    }
    case Op::Navigate:
        if (auto* v = view(viewId, op)) v->navigateIPC(r.str());
        return;
    case Op::Evaluate:
        if (auto* v = view(viewId, op)) v->evaluateIPC(r.str());
        return;
    case Op::Screenshot: {
        uint8_t fmt = r.u8();
        uint8_t q = r.u8();
        if (auto* v = view(viewId, op)) v->screenshotIPC(fmt, q);
        return;
    }
    case Op::Close:
        views.erase(viewId);
        writer.sendReply(viewId, Reply::Ack);
        return;
    case Op::Resize: {
        auto p = decode<ResizePayload>(r);
        if (auto* v = view(viewId, op)) {
            v->resize(p.width, p.height);
            writer.sendReply(viewId, Reply::Ack);
        }
        return;
    }
    case Op::GoBack:
        if (auto* v = view(viewId, op)) {
            v->goBack();
            writer.sendReply(viewId, Reply::Ack);
        }
        return;
    case Op::GoForward:
        if (auto* v = view(viewId, op)) {
            v->goForward();
            writer.sendReply(viewId, Reply::Ack);
        }
        return;
    case Op::Reload:
        if (auto* v = view(viewId, op)) {
            v->reload();
            writer.sendReply(viewId, Reply::Ack);
        }
        return;
    // Input ops: return true = async (completion block Acks), false = sync.
    case Op::Click: {
        auto p = decode<ClickPayload>(r);
        if (auto* v = view(viewId, op)) {
            if (!v->clickIPC(p.x, p.y, p.button, p.modifiers, p.clickCount)) writer.sendReply(viewId, Reply::Ack);
        }
        return;
    }
    case Op::Type:
        if (auto* v = view(viewId, op)) {
            if (!v->typeIPC(r.str())) writer.sendReply(viewId, Reply::Ack);
        }
        return;
    case Op::Press: {
        auto p = decode<PressPayload>(r);
        auto vk = static_cast<VirtualKey>(p.virtualKey);
        WTF::String ch = (vk == VirtualKey::Character) ? r.str() : WTF::String();
        if (auto* v = view(viewId, op)) {
            if (!v->pressIPC(vk, p.modifiers, ch)) writer.sendReply(viewId, Reply::Ack);
        }
        return;
    }
    case Op::Scroll: {
        auto p = decode<ScrollPayload>(r);
        if (auto* v = view(viewId, op)) {
            if (!v->scrollIPC(p.deltaX, p.deltaY)) writer.sendReply(viewId, Reply::Ack);
        }
        return;
    }
    case Op::ClickSelector: {
        auto p = decode<ClickSelectorPayload>(r);
        if (auto* v = view(viewId, op)) {
            if (!v->clickSelectorIPC(r.str(), p.timeout, p.button, p.modifiers, p.clickCount)) writer.sendReply(viewId, Reply::Ack);
        }
        return;
    }
    case Op::ScrollTo: {
        auto p = decode<ScrollToPayload>(r);
        if (auto* v = view(viewId, op)) {
            if (!v->scrollToIPC(r.str(), p.timeout, p.block)) writer.sendReply(viewId, Reply::Ack);
        }
        return;
    }
    }
    writer.sendReplyStr(viewId, Reply::Error, "unknown op"_s);
}

static void cfCallback(CFFileDescriptorRef, CFOptionFlags flags, void*)
{
    if (flags & kCFFileDescriptorReadCallBack) g_host->onReadable();
    if (flags & kCFFileDescriptorWriteCallBack) g_host->writer.onWritable();
}

} // namespace WebViewProto
} // namespace Bun

// ---------------------------------------------------------------------------
// Entry. cli.zig calls this before anything else when BUN_INTERNAL_WEBVIEW_HOST
// is set. Never returns.
// ---------------------------------------------------------------------------
extern "C" [[noreturn]] void Bun__WebView__hostMain(int32_t fd) noexcept
{
    using namespace Bun;
    using namespace Bun::WebViewProto;

    // dup2 preserved the parent-side flags on the parent end, not ours.
    // Set nonblocking here; the CFFileDescriptor callback reads to EAGAIN.
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) {
        perror("webview-host: configure IPC socket");
        _exit(71);
    }

    if (!loadHostCF()) {
        fprintf(stderr, "webview-host: CoreFoundation dlopen failed\n");
        _exit(70); // EX_SOFTWARE
    }
    // ObjCRuntime loads AppKit + WebKit + objc. sharedApplication with
    // ActivationPolicyAccessory so no dock tile for the host.
    auto* rt = ObjCRuntime::tryLoad();
    if (!rt->m_loaded) {
        fprintf(stderr, "webview-host: %s\n", rt->m_loadError.utf8().data());
        _exit(70);
    }

    // App Nap suppresses the host process on CI — no user interaction, no
    // visible window, ActivationPolicyAccessory. The CVDisplayLink callback
    // fires but the main run loop is throttled; the IPC send to WebContent
    // doesn't reach it, rAF never fires. WebKitTestRunner disables it
    // (main.mm:59). WebContent-side App Nap is handled separately via
    // WKPreferences._pageVisibilityBasedProcessSuppressionEnabled = NO.
    {
        ObjCRuntime::ARPool pool;
        objc::NSProcessInfo::disableAppNap();
    }

    g_host.construct();
    g_host->fd = fd;
    g_host->cffd = cf.CFFileDescriptorCreate(nullptr, fd, /*closeOnInvalidate*/ true, cfCallback, nullptr);
    if (!g_host->cffd) {
        fprintf(stderr, "webview-host: create IPC descriptor failed\n");
        _exit(71);
    }
    g_host->writer.init(fd, g_host->cffd);

    CFRunLoopSourceRef src = cf.CFFileDescriptorCreateRunLoopSource(nullptr, g_host->cffd, 0);
    if (!src) {
        fprintf(stderr, "webview-host: create IPC run-loop source failed\n");
        _exit(71);
    }
    cf.CFRunLoopAddSource(cf.CFRunLoopGetCurrent(), src, cf.kCFRunLoopDefaultMode);
    cf.CFFileDescriptorEnableCallBacks(g_host->cffd, kCFFileDescriptorReadCallBack);

    cf.CFRunLoopRun();
    // Reached on socket EOF (parent died) or explicit stop. Views are
    // already cleared in onReadable's EOF path.
    _exit(0);
}

#endif // OS(DARWIN)
