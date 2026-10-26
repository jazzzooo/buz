// WebKitBackend: HostClient (usockets wire to the host subprocess) + all
// WK::Ops (per-view IPC commands). JSWebView's dispatching instance methods
// call into WK::Ops::*; everything Darwin-specific lives here.

#include "root.h"
#include "SchemaBindings.h"
#include "WebKitBackend.h"
#include <wtf/Scope.h>
#include "JSWebView.h"
#include "blob.h"

#if OS(DARWIN)

#include "bun-uws/src/SocketKinds.h"
#include "../../webview_sys/ipc_protocol.h"
#include "ZigGlobalObject.h"
#include "BunClientData.h"
#include "JSBuffer.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/Weak.h>
#include <JavaScriptCore/WeakInlines.h>
#include <JavaScriptCore/ConsoleClient.h>
#include <JavaScriptCore/ScriptArguments.h>
#include <JavaScriptCore/Strong.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/Base64.h>
#include <new>
#include <cstdlib>
#include <limits>

#include "libusockets.h"
#include "_libusockets.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

namespace Bun {
namespace WK {

using namespace JSC;
using namespace WebViewProto;

static void unmapOwnedBytes(void*, uint8_t* ptr, size_t length)
{
    munmap(ptr, length);
}
// Bracket the whole onData batch. exit() drains microtasks when outermost,
// so all the promise reactions from this batch run before we return to usockets.
// WebView event dispatch nests enter/exit and reports callback exceptions, so
// one bad onNavigated callback cannot poison the rest of the batch.

HostClient& client(JSC::VM& vm)
{
    return *WebCore::clientData(vm)->webViewHostClient;
}

HostClient::~HostClient()
{
    shutdown();
    if (socketGroup.loop)
        us_socket_group_deinit(&socketGroup);
}

void HostClient::shutdown()
{
    if (std::exchange(isShutdown, true)) return;
    reset();
}

void HostClient::reset()
{
    dead = true;
    ++connectionGeneration;
    if (auto* socket = std::exchange(sock, nullptr))
        us_socket_close(socket, 0, nullptr);
    for (auto& [id, weak] : viewsById) {
        if (auto* view = weak.get()) {
            view->wrapped().m_closed = true;
            view->wrapped().m_loading = false;
            abandonPendingOps(view);
        }
    }
    viewsById.clear();
    rx.clear();
    rxConsumed = 0;
    receivedDescriptors.clear();
    txQueue.clear();
    updateKeepAlive();
    global = nullptr;
    globalRoot.clear();
}

static HostClient& clientForSocket(us_socket_t* socket)
{
    return *static_cast<HostClient*>(us_socket_group(socket)->ext);
}

static us_socket_t* hostOnData(us_socket_t* s, char* data, int length)
{
    auto& owner = clientForSocket(s);
    if (owner.sock == s) owner.onData(data, length);
    return s;
}
static us_socket_t* hostOnWritable(us_socket_t* s)
{
    auto& owner = clientForSocket(s);
    if (owner.sock == s) owner.onWritable();
    return s;
}
static us_socket_t* hostOnDescriptor(us_socket_t* s, int fd)
{
    WTF::UnixFileDescriptor descriptor { fd, WTF::UnixFileDescriptor::Adopt };
    auto& owner = clientForSocket(s);
    if (owner.sock == s) owner.onDescriptor(WTF::move(descriptor));
    return s;
}
static us_socket_t* hostOnClose(us_socket_t* s, int, void*)
{
    auto& owner = clientForSocket(s);
    if (owner.sock == s) owner.onClose();
    return s;
}
static us_socket_t* hostOnEnd(us_socket_t* s)
{
    auto& owner = clientForSocket(s);
    if (owner.sock == s) owner.onClose();
    return s;
}
static us_socket_t* hostOnOpen(us_socket_t* s, int, char*, int) { return s; }

static constexpr us_socket_vtable_t s_hostVTable = {
    .on_open = hostOnOpen,
    .on_data = hostOnData,
    .on_fd = hostOnDescriptor,
    .on_writable = hostOnWritable,
    .on_close = hostOnClose,
    .on_timeout = nullptr,
    .on_long_timeout = nullptr,
    .on_end = hostOnEnd,
    .on_connect_error = nullptr,
    .on_connecting_error = nullptr,
    .on_handshake = nullptr,
};

// us_socket_ref/unref are no-ops on kqueue, and us_poll_start_rc doesn't
// touch loop.active. Track our own ref against view count. A view with
// pending ops keeps itself alive via visitChildren → promise → reaction
// → closure → view, so "any views" covers "any pending".
void HostClient::updateKeepAlive()
{
    bool want = !viewsById.empty();
    if (want == sockRefd) return;
    sockRefd = want;
    if (want)
        Bindgen::ZigExports::bunBindgenZig_EventLoop_eventLoopRefConcurrently(bunVM);
    else
        Bindgen::ZigExports::bunBindgenZig_EventLoop_eventLoopUnrefConcurrently(bunVM);
}

bool HostClient::ensureSpawned(Zig::GlobalObject* zig, bool stdoutInherit, bool stderrInherit)
{
    auto scope = DECLARE_THROW_SCOPE(zig->vm());
    if (isShutdown) return false;
    if (sock && !dead) return true;
    ++connectionGeneration;

    if (dead) {
        dead = false;
        sock = nullptr;
        rx.clear();
        rxConsumed = 0;
        receivedDescriptors.clear();
        txQueue.clear();
    }

    int fd = Bindgen::ZigExports::bunBindgenZig_WebViewHostProcess_webViewHostProcessEnsure(zig, connectionGeneration, stdoutInherit, stderrInherit);
    if (scope.exception()) {
        dead = true;
        return false;
    }
    if (fd < 0) {
        dead = true;
        return false;
    }
    global = zig;
    globalRoot.set(zig->vm(), zig);

    // Socket group — once. Embedded; lazily linked into the loop on first
    // socket. on_open won't fire (us_socket_from_fd doesn't call it) but a
    // null vtable entry is fine — dispatch skips nulls.
    if (!socketGroup.loop) {
        us_socket_group_init(&socketGroup, uws_get_loop(), &s_hostVTable, this);
    }

    // us_socket_from_fd sets nonblocking/nodelay/no-sigpipe and polls
    // READABLE|WRITABLE. IPC mode delivers screenshot descriptors before data.
    // us_poll_start doesn't touch loop.active; updateKeepAlive is the
    // sole ref manager. kind=1 (.dynamic) → dispatch via s_hostVTable.
    us_connect_error_t failure;
    sock = us_socket_from_fd(&socketGroup, BUN_SOCKET_KIND_DYNAMIC, nullptr, sizeof(void*), fd, 1, &failure);
    if (!sock) {
        // us_socket_from_fd calls us_poll_free on failure but doesn't close
        // the fd (ownership was ours). Leak it and the child stays alive
        // forever with a dead read end.
        ::close(fd);
        dead = true;
        return false;
    }
    return true;
}

bool HostClient::writeFrame(Op op, uint32_t viewId, const uint8_t* payload, size_t len)
{
    if (!sock || dead || us_socket_is_closed(sock)) return false;
    if (len > kMaxFrameLen || (len && !payload)) {
        rejectAllAndMarkDead("Invalid WebView request payload"_s);
        return false;
    }
    Frame h = { static_cast<uint32_t>(len), viewId, static_cast<uint8_t>(op) };
    const auto* hbytes = reinterpret_cast<const uint8_t*>(&h);
    size_t skip = 0;
    if (txQueue.isEmpty()) {
        // us_socket_write2 does writev(header, payload) and auto-enables the
        // writable poll on short write. Returns bytes written (≥0, never -1).
        int w = us_socket_write2(sock,
            reinterpret_cast<const char*>(hbytes), sizeof(h),
            reinterpret_cast<const char*>(payload), static_cast<int>(len));
        size_t total = sizeof(h) + len;
        if (static_cast<size_t>(w) == total) return true;
        skip = static_cast<size_t>(w);
    }
    if (skip < sizeof(h)) {
        if (!txQueue.tryAppend(std::span<const uint8_t>(hbytes + skip, sizeof(h) - skip))) {
            rejectAllAndMarkDead("Unable to queue WebView request"_s);
            return false;
        }
        skip = 0;
    } else {
        skip -= sizeof(h);
    }
    if (len > skip && !txQueue.tryAppend(std::span<const uint8_t>(payload + skip, len - skip))) {
        rejectAllAndMarkDead("Unable to queue WebView request"_s);
        return false;
    }
    return true;
}

void HostClient::onWritable()
{
    while (!txQueue.isEmpty()) {
        int w = us_socket_write(sock,
            reinterpret_cast<const char*>(txQueue.span().data()),
            static_cast<int>(std::min(txQueue.size(), static_cast<size_t>(std::numeric_limits<int>::max()))));
        if (w <= 0) return; // usockets re-enables writable poll on short write
        txQueue.removeAt(0, static_cast<size_t>(w));
    }
}

// Allocator teardown may poison adopted bytes, so the mapping must be writable.
static void* mapShm(int fd, size_t byteLen, int& outErr)
{
    struct stat info;
    if (fstat(fd, &info) != 0) {
        outErr = errno;
        return nullptr;
    }
    if (info.st_size < 0 || static_cast<uint64_t>(info.st_size) != byteLen) {
        outErr = EINVAL;
        return nullptr;
    }
    void* map = mmap(nullptr, byteLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    outErr = (map == MAP_FAILED) ? errno : 0;
    if (map == MAP_FAILED) return nullptr;
    return map;
}

static JSValue namedScreenshot(JSGlobalObject* g, std::span<const uint8_t> bytes, bool& ok)
{
    auto& vm = g->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    char name[32];
    snprintf(name, sizeof(name), "/bun-wv-%08x%08x", arc4random(), arc4random());
    WTF::UnixFileDescriptor fd { shm_open(name, O_CREAT | O_RDWR | O_EXCL, 0600), WTF::UnixFileDescriptor::Adopt };
    if (!fd)
        return createError(g, makeString("shm_open: "_s, WTF::String::fromUTF8(strerror(errno))));
    bool committed = false;
    auto unlinkGuard = makeScopeExit([&] {
        if (!committed) shm_unlink(name);
    });
    if (ftruncate(fd.value(), static_cast<off_t>(bytes.size())) != 0)
        return createError(g, makeString("ftruncate: "_s, WTF::String::fromUTF8(strerror(errno))));
    void* map = mmap(nullptr, bytes.size(), PROT_READ | PROT_WRITE, MAP_SHARED, fd.value(), 0);
    if (map == MAP_FAILED)
        return createError(g, makeString("mmap: "_s, WTF::String::fromUTF8(strerror(errno))));
    memcpy(map, bytes.data(), bytes.size());
    munmap(map, bytes.size());

    auto* obj = constructEmptyObject(g);
    RETURN_IF_EXCEPTION(scope, {});
    obj->putDirect(vm, Identifier::fromString(vm, "name"_s),
        jsString(vm, WTF::String::fromUTF8(name)));
    RETURN_IF_EXCEPTION(scope, {});
    obj->putDirect(vm, Identifier::fromString(vm, "size"_s), jsNumber(bytes.size()));
    RETURN_IF_EXCEPTION(scope, {});
    committed = true;
    ok = true;
    return obj;
}

static JSValue openShmScreenshot(JSGlobalObject* g, int fd, uint32_t byteLen, const char* mime, ScreenshotEncoding enc, bool& ok)
{
    ok = false;
    auto& vm = g->vm();

    int shmErr = 0;
    void* map = mapShm(fd, byteLen, shmErr);
    if (!map)
        return createError(g, makeString("shm: "_s, WTF::String::fromUTF8(strerror(shmErr))));

    switch (enc) {
    case ScreenshotEncoding::Blob: {
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* owner = bun_bindgen_byte_owner_create(static_cast<uint8_t*>(map), byteLen, nullptr, unmapOwnedBytes);
        if (!owner) {
            munmap(map, byteLen);
            return createOutOfMemoryError(g);
        }
        auto* impl = Bindgen::ZigExports::bunBindgenZig_Blob_blobAdoptOwnedBytesWithType(
            g, owner, WTF::String::fromLatin1(mime));
        RETURN_IF_EXCEPTION(scope, {});
        auto blob = WebCore::adoptBlobImpl(defaultGlobalObject(g), impl);
        RETURN_IF_EXCEPTION(scope, {});
        ok = true;
        return blob;
    }
    case ScreenshotEncoding::Buffer: {
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* owner = bun_bindgen_byte_owner_create(static_cast<uint8_t*>(map), byteLen, nullptr, unmapOwnedBytes);
        if (!owner) {
            munmap(map, byteLen);
            return createOutOfMemoryError(g);
        }
        auto backing = Bindgen::adoptByteOwner(owner);
        if (!backing)
            return createOutOfMemoryError(g);
        auto* result = WebCore::createBuffer(g, backing.releaseNonNull());
        RETURN_IF_EXCEPTION(scope, {});
        ok = true;
        return result;
    }
    case ScreenshotEncoding::Base64: {
        // base64Encode copies into the output String — one
        // materialization, unavoidable (the user explicitly wants the
        // text form). WTF's encoder is vectorized (SIMD on the 3→4
        // table-lookup). Unmap after — the string owns its own copy.
        WTF::String b64 = WTF::base64EncodeToStringReturnNullIfOverflow(
            std::span<const uint8_t>(static_cast<const uint8_t*>(map), byteLen));
        munmap(map, byteLen);
        if (b64.isNull()) return createOutOfMemoryError(g);
        ok = true;
        return jsString(vm, WTF::move(b64));
    }
    case ScreenshotEncoding::Shmem: {
        auto unmapGuard = makeScopeExit([&] { munmap(map, byteLen); });
        return namedScreenshot(g, { static_cast<const uint8_t*>(map), byteLen }, ok);
    }
    }
    RELEASE_ASSERT_NOT_REACHED();
    return jsUndefined();
}

void HostClient::handleReply(const Frame& h, Reader r)
{
    auto* g = global;
    auto& vm = g->vm();
    auto reply = static_cast<Reply>(h.op);
    if (!validPayload(reply, r)) {
        rejectAllAndMarkDead("WebView host sent an invalid reply payload"_s);
        return;
    }
    WTF::UnixFileDescriptor screenshotDescriptor;
    if (reply == Reply::ScreenshotDone) {
        if (h.len != sizeof(uint32_t) || receivedDescriptors.isEmpty()) {
            rejectAllAndMarkDead("WebView host sent an invalid screenshot transfer"_s);
            return;
        }
        screenshotDescriptor = WTF::move(receivedDescriptors[0]);
        receivedDescriptors.removeAt(0);
    }

    auto it = viewsById.find(h.viewId);
    if (it == viewsById.end()) return;
    JSWebView* view = it->second.get();
    if (!view) return; // collected — user dropped both view and promise

    switch (reply) {
    // Events fire the callback; they arrive BEFORE the matching Done/Failed
    // reply so the callback observes the state change before `await` resumes.
    case Reply::NavEvent: {
        WTF::String url = r.str();
        WTF::String title = r.str();
        view->wrapped().m_url = url;
        view->wrapped().m_title = title;
        view->wrapped().m_loading = false;
        if (JSValue cb = view->raw_slot_onNavigated(); cb && cb.isCallable()) {
            Bun::Bindgen::ZigExports::bunBindgenZig_webview_dispatchNavigated(
                g,
                cb.getObject(),
                url,
                title);
        }
        return;
    }
    case Reply::NavFailEvent: {
        WTF::String err = r.str();
        view->wrapped().m_loading = false;
        if (JSValue cb = view->raw_slot_onNavigationFailed(); cb && cb.isCallable()) {
            Bun::Bindgen::ZigExports::bunBindgenZig_webview_dispatchNavigationFailed(
                g,
                cb.getObject(),
                createError(g, err));
        }
        return;
    }

    case Reply::ConsoleEvent: {
        if (!view->wrapped().m_consoleIsGlobal && !view->raw_slot_onConsole()) return;
        WTF::String type = r.str();
        uint32_t argCount = r.u32();

        MarkedArgumentBuffer args;
        for (uint32_t i = 0; i < argCount; ++i) {
            WTF::String s = r.str();
            // Each arg was JSON.stringify'd page-side; JSONParse to recover
            // the structured value. Primitives round-trip losslessly; objects
            // get their JSON representation. Values JSON.stringify can't
            // serialize (functions, undefined) fell back to String(x) in the
            // user script — JSONParse returns {} for those.
            JSValue v = s.isEmpty() ? jsUndefined() : JSONParse(g, s);
            args.append(v ? v : jsUndefined());
        }

        if (view->wrapped().m_consoleIsGlobal) {
            // ConsoleClient::logWithLevel — same path as native
            // console.log(). trace/dir render through Log level.
            using JSC::MessageLevel;
            MessageLevel ml = MessageLevel::Log;
            if (type == "error"_s)
                ml = MessageLevel::Error;
            else if (type == "warn"_s)
                ml = MessageLevel::Warning;
            else if (type == "debug"_s)
                ml = MessageLevel::Debug;
            else if (type == "info"_s)
                ml = MessageLevel::Info;

            WTF::Vector<Strong<Unknown>> strongArgs;
            strongArgs.reserveInitialCapacity(args.size());
            for (unsigned i = 0; i < args.size(); ++i)
                strongArgs.append(Strong<Unknown>(vm, args.at(i)));
            auto scriptArgs = Inspector::ScriptArguments::create(g, WTF::move(strongArgs));
            if (auto clientRef = g->consoleClient())
                clientRef->logWithLevel(g, WTF::move(scriptArgs), ml);
            return;
        }

        // Custom callback: (type, ...args).
        JSValue cbValue = view->raw_slot_onConsole();
        if (!cbValue || !cbValue.isCell()) return;
        JSObject* cb = cbValue.getObject();
        auto callData = getCallData(cb);
        if (callData.type == CallData::Type::None) return;
        MarkedArgumentBuffer cbArgs;
        cbArgs.append(jsString(vm, type.isEmpty() ? "log"_s : type));
        for (unsigned i = 0; i < args.size(); ++i)
            cbArgs.append(args.at(i));
        call(g, cb, callData, jsUndefined(), cbArgs);
        return;
    }

    case Reply::NavDone:
        // url/title already cached by the preceding NavEvent.
        settleSlot(g, view, PendingOp::Navigate, true, jsUndefined());
        return;
    case Reply::NavFailed:
        // navigateIPC sends NavFailed directly for invalid URLs — no
        // NavFailEvent precedes it, so the only m_loading reset path is here.
        view->wrapped().m_loading = false;
        settleSlot(g, view, PendingOp::Navigate, false, createError(g, r.str()));
        return;

    case Reply::EvalDone: {
        WTF::String s = r.str();
        // Child serialized via JSON.stringify page-side; this is the one
        // deserialization. Empty string = script returned undefined (or a
        // function/symbol — JSON.stringify collapses those to undefined).
        // JSONParse returns {} on malformed input; the child's output is
        // JSC's own JSON.stringify so it's well-formed by construction.
        JSValue v = s.isEmpty() ? jsUndefined() : JSONParse(g, s);
        settleSlot(g, view, PendingOp::Evaluate, true, v ? v : jsUndefined());
        return;
    }
    case Reply::EvalFailed:
        settleSlot(g, view, PendingOp::Evaluate, false, createError(g, r.str()));
        return;

    case Reply::ScreenshotDone: {
        if (!pendingOp(view, PendingOp::Screenshot)) return;
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(g->vm());
        uint32_t byteLen = r.u32();
        bool ok;
        JSValue result = openShmScreenshot(g, screenshotDescriptor.value(), byteLen,
            screenshotMimeType(view->wrapped().m_screenshotFormat),
            view->wrapped().m_screenshotEncoding, ok);
        if (auto* exception = scope.exception()) {
            auto error = exception->value();
            if (!scope.clearExceptionExceptTermination()) return;
            settleSlot(g, view, PendingOp::Screenshot, false, error);
            return;
        }
        settleSlot(g, view, PendingOp::Screenshot, ok, result);
        return;
    }
    case Reply::ScreenshotFailed:
        settleSlot(g, view, PendingOp::Screenshot, false, createError(g, r.str()));
        return;

    case Reply::Ack:
        settleSlot(g, view, PendingOp::Misc, true, jsUndefined());
        return;
    case Reply::Error:
        // Child-side misc-op failure (input contention, selector timeout,
        // malformed result). The child's view() lookup now sends op-specific
        // failure types for invalid viewId (NavFailed/EvalFailed/etc.), so
        // Error is exclusively misc-slot. Rejecting all slots here would
        // spuriously kill a concurrent navigate.
        view->wrapped().m_loading = false;
        settleSlot(g, view, PendingOp::Misc, false, createError(g, r.str()));
        return;
    }
}

void HostClient::rejectAllAndMarkDead(const WTF::String& reason)
{
    if (dead) return;
    dead = true;
    // Process exit can arrive before socket EOF.
    if (auto* s = std::exchange(sock, nullptr)) us_socket_close(s, 0, nullptr);
    receivedDescriptors.clear();
    auto views = std::exchange(viewsById, {});
    updateKeepAlive();
    for (auto& [id, weak] : views) {
        if (auto* view = weak.get()) {
            view->wrapped().m_closed = true;
            view->wrapped().m_loading = false;
        }
    }
    if (!global) return;
    auto* g = global;
    JSValue err = createError(g, reason);
    for (auto& [id, weak] : views) {
        JSWebView* v = weak.get();
        if (!v) continue;
        rejectPendingOps(g, v, err);
    }
}

void HostClient::onClose()
{
    rejectAllAndMarkDead("WebView host process died"_s);
}

void HostClient::onDescriptor(WTF::UnixFileDescriptor descriptor)
{
    if (dead) return;
    if (fcntl(descriptor.value(), F_SETFD, FD_CLOEXEC) < 0
        || !receivedDescriptors.tryAppend(WTF::move(descriptor)))
        rejectAllAndMarkDead("Unable to receive WebView screenshot descriptor"_s);
}

void HostClient::onData(const char* data, int length)
{
    if (dead) return;
    if (length && !rx.tryAppend(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(data), static_cast<size_t>(length)))) {
        rejectAllAndMarkDead("Unable to buffer WebView host data"_s);
        return;
    }
    auto generation = connectionGeneration;
    auto* frameGlobal = global;

    auto& vm = frameGlobal->vm();
    // TopExceptionScope is the event-loop catch-all (same pattern as
    // performMicrotaskCheckpoint). Its dtor doesn't simulate.
    auto catchScope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_enter(frameGlobal);
    auto exitLoop = makeScopeExit([frameGlobal] { Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_exit(frameGlobal); });

    while (!dead && generation == connectionGeneration && rx.size() - rxConsumed >= sizeof(Frame)) {
        Frame h;
        memcpy(&h, rx.span().data() + rxConsumed, sizeof(h));
        if (h.len > kMaxFrameLen) [[unlikely]] {
            // Child memory corruption. Stop parsing; rx tail is dead weight
            // until socket close, but we won't livelock growing it forever.
            rejectAllAndMarkDead("WebView host sent a corrupt frame"_s);
            break;
        }
        if (rx.size() - rxConsumed < sizeof(Frame) + h.len) break;
        WTF::Vector<uint8_t, 256> payload;
        bool copied = payload.tryAppend(rx.span().subspan(rxConsumed + sizeof(Frame), h.len));
        if (!copied) {
            rejectAllAndMarkDead("Unable to decode WebView host data"_s);
        } else {
            Reader r { payload.span().data(), payload.span().data() + payload.size() };
            // A nested dispatch must start after this owned frame.
            rxConsumed += sizeof(Frame) + h.len;
            handleReply(h, r);
        }
        // Value construction can throw (OOM). Report +
        // clear so one bad frame doesn't poison the rest of the batch.
        if (auto* exception = catchScope.exception()) [[unlikely]] {
            if (!catchScope.clearExceptionExceptTermination()) {
                break;
            }
            frameGlobal->reportUncaughtExceptionAtEventLoop(frameGlobal, exception);
        }
        if (!copied) break;
    }
    if (generation == connectionGeneration && rxConsumed) {
        rx.removeAt(0, rxConsumed);
        rxConsumed = 0;
    }
}

// --- WK::Ops ---------------------------------------------------------------
// Called from JSWebView's dispatching instance methods. Wire encoding is
// the typed payload structs from ipc_protocol.h.

void throwPayloadError(JSGlobalObject* global, PayloadError error)
{
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    switch (error) {
    case PayloadError::OutOfMemory:
        throwOutOfMemoryError(global, scope);
        return;
    case PayloadError::TooLarge:
        throwRangeError(global, scope, "WebView IPC payload exceeds the size limit"_s);
        return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

namespace Ops {

// Create promise, store in barrier, write frame. Caller guarantees the slot
// is empty (INVALID_STATE thrown in the prototype method before calling into
// the instance method that ends up here).
static JSPromise* sendOp(JSGlobalObject* g, JSWebView* view, PendingOp slot,
    Op op, const uint8_t* payload, size_t len)
{
    auto& vm = g->vm();
    auto* promise = JSPromise::create(vm, g->promiseStructure());
    auto& c = client(g->vm());
    if (!c.sock || c.dead || us_socket_is_closed(c.sock)) {
        promise->reject(vm, createError(g, "WebView host process is not running"_s));
        return promise;
    }
    setPendingOp(vm, view, slot, promise);
    c.writeFrame(op, view->wrapped().m_viewId, payload, len);
    return promise;
}

static JSPromise* sendOp(JSGlobalObject* g, JSWebView* view, PendingOp slot, Op op, const EncodedPayload& payload)
{
    if (!payload) {
        throwPayloadError(g, payload.error());
        return nullptr;
    }
    return sendOp(g, view, slot, op, payload->span().data(), payload->size());
}

JSPromise* navigate(JSGlobalObject* g, JSWebView* view, const WTF::String& url)
{
    auto payload = encodeStr(url);
    auto* promise = sendOp(g, view, PendingOp::Navigate, Op::Navigate, payload);
    if (pendingOp(view, PendingOp::Navigate)) view->wrapped().m_loading = true;
    return promise;
}

JSPromise* evaluate(JSGlobalObject* g, JSWebView* view, const WTF::String& script)
{
    auto payload = encodeStr(script);
    return sendOp(g, view, PendingOp::Evaluate, Op::Evaluate, payload);
}

JSPromise* screenshot(JSGlobalObject* g, JSWebView* view, ScreenshotFormat format, uint8_t quality)
{
    uint8_t payload[2] = { static_cast<uint8_t>(format), quality };
    return sendOp(g, view, PendingOp::Screenshot, Op::Screenshot, payload, sizeof(payload));
}

JSPromise* click(JSGlobalObject* g, JSWebView* view, float x, float y, uint8_t button, uint8_t modifiers, uint8_t clickCount)
{
    auto payload = encode(ClickPayload { x, y, button, modifiers, clickCount });
    return sendOp(g, view, PendingOp::Misc, Op::Click, payload);
}

JSPromise* clickSelector(JSGlobalObject* g, JSWebView* view, const WTF::String& selector, uint32_t timeout, uint8_t button, uint8_t modifiers, uint8_t clickCount)
{
    auto payload = encode(ClickSelectorPayload { timeout, button, modifiers, clickCount }, selector);
    return sendOp(g, view, PendingOp::Misc, Op::ClickSelector, payload);
}

JSPromise* type(JSGlobalObject* g, JSWebView* view, const WTF::String& text)
{
    auto payload = encodeStr(text);
    return sendOp(g, view, PendingOp::Misc, Op::Type, payload);
}

JSPromise* press(JSGlobalObject* g, JSWebView* view, VirtualKey key, uint8_t modifiers, const WTF::String& character)
{
    auto payload = encode(PressPayload { static_cast<uint8_t>(key), modifiers },
        key == VirtualKey::Character ? character : WTF::String());
    return sendOp(g, view, PendingOp::Misc, Op::Press, payload);
}

JSPromise* scroll(JSGlobalObject* g, JSWebView* view, double dx, double dy)
{
    auto payload = encode(ScrollPayload { static_cast<float>(dx), static_cast<float>(dy) });
    return sendOp(g, view, PendingOp::Misc, Op::Scroll, payload);
}

JSPromise* scrollTo(JSGlobalObject* g, JSWebView* view, const WTF::String& selector, uint32_t timeout, uint8_t block)
{
    auto payload = encode(ScrollToPayload { timeout, block }, selector);
    return sendOp(g, view, PendingOp::Misc, Op::ScrollTo, payload);
}

JSPromise* resize(JSGlobalObject* g, JSWebView* view, uint32_t width, uint32_t height)
{
    auto payload = encode(ResizePayload { width, height });
    return sendOp(g, view, PendingOp::Misc, Op::Resize, payload);
}

JSPromise* goBack(JSGlobalObject* g, JSWebView* view)
{
    return sendOp(g, view, PendingOp::Misc, Op::GoBack, nullptr, 0);
}

JSPromise* goForward(JSGlobalObject* g, JSWebView* view)
{
    return sendOp(g, view, PendingOp::Misc, Op::GoForward, nullptr, 0);
}

JSPromise* reload(JSGlobalObject* g, JSWebView* view)
{
    return sendOp(g, view, PendingOp::Misc, Op::Reload, nullptr, 0);
}

void close(JSWebView* view)
{
    auto& c = client(view->vm());
    if (c.global) {
        auto* g = c.global;
        JSValue err = createError(g, "WebView closed"_s);
        rejectPendingOps(g, view, err);
    }
    view->wrapped().closeNative();
}

} // namespace Ops

} // namespace WK
} // namespace Bun

// Process exit and socket closure can arrive in either order.
void Bun::Bindgen::Engine::bunBindgenEngine_WebViewHostProcess_webViewHostProcessDied(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebViewHostProcess_webViewHostProcessDied_Arguments& args)
{
    auto& c = Bun::WK::client(context.globalObject.vm());
    if (c.dead || c.connectionGeneration != args.generation) return;
    c.rejectAllAndMarkDead(args.signo
            ? makeString("WebView host process killed by signal "_s, args.signo)
            : "WebView host process exited"_s);
}

#else // !OS(DARWIN)

// The process-exit handler remains linked on every platform even though host
// process creation is gated on macOS.
void Bun::Bindgen::Engine::bunBindgenEngine_WebViewHostProcess_webViewHostProcessDied(
    Bun::Bindgen::EngineCallContext&,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebViewHostProcess_webViewHostProcessDied_Arguments&) {}

#endif // OS(DARWIN)
