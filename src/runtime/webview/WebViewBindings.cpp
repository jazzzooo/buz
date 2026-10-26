// WebView implementations behind the generated bindings. Argument
// conversion, the wrapper cell, prototype, and constructor all come from
// WebView.schema.zig; this file owns construction sequencing, the pending-op
// slot protocol, and per-backend dispatch into WK::Ops / CDP::Ops.

#include "root.h"
#include "WebViewBindings.h"
#include "SchemaBindings.h"
#include "JSWebView.h"
#include "ChromeBackend.h"
#include "WebKitBackend.h"
#include "../../webview_sys/ipc_protocol.h"
#include "ZigGlobalObject.h"
#include "BunClientData.h"
#include "ErrorCode.h"
#include "DOMWrapperWorld.h"
#include "JSDOMWrapperCache.h"
#include "ScriptExecutionContext.h"
#include <JavaScriptCore/ConsoleObject.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/Weak.h>
#include <JavaScriptCore/WeakInlines.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/MakeString.h>

namespace Bun {

using namespace JSC;
using namespace WebViewProto;

WTF_MAKE_TZONE_ALLOCATED_IMPL(WebViewEventTarget);

RefPtr<WebViewEventTarget> WebViewEventTarget::create(WebCore::ScriptExecutionContext& context)
{
    auto finalizer = Bindgen::ZigExports::bunBindgenZig_webview_createWebViewFinalizer(bunVM(context.vm()));
    if (!finalizer)
        return nullptr;
    return adoptRef(*new WebViewEventTarget(context, finalizer.value()));
}

void WebViewEventTarget::deref() const
{
    if (derefBase())
        Bindgen::ZigExports::bunBindgenZig_webview_enqueueWebViewFinalizer(
            std::exchange(m_finalizer, nullptr), const_cast<WebViewEventTarget*>(this));
}

WebViewEventTarget::~WebViewEventTarget()
{
    ASSERT(!m_finalizer);
    ASSERT(m_backendReleased);
}

void WebViewEventTarget::closeNative(bool shuttingDown)
{
    if (std::exchange(m_backendReleased, true)) return;
    shuttingDown |= !scriptExecutionContext();
    m_closed = true;
    m_loading = false;
    if (!m_viewId) return;
    if (m_backend == WebViewBackend::Chrome) {
        auto& t = CDP::transport(m_vm);
        if (m_connectionGeneration != t.m_connectionGeneration) return;
        t.cancelViewRequests(m_viewId);
        if (!shuttingDown)
            t.closeTarget(m_targetId);
        if (!m_sessionId.isEmpty()) t.m_sessions.remove(m_sessionId);
        t.m_views.remove(m_viewId);
        if (!shuttingDown)
            t.updateKeepAlive();
        return;
    }
#if OS(DARWIN)
    auto& c = WK::client(m_vm);
    if (m_connectionGeneration != c.connectionGeneration) return;
    if (!shuttingDown)
        c.writeFrame(Op::Close, m_viewId, nullptr, 0);
    c.viewsById.erase(m_viewId);
    if (!shuttingDown)
        c.updateKeepAlive();
#endif
}

void Bindgen::Engine::releaseWebViewNative(WebViewEventTarget* view)
{
    delete view;
}

void Bindgen::Engine::releaseWebViewFinalizer(WebViewFinalizer* finalizer)
{
    Bindgen::ZigExports::bunBindgenZig_webview_discardWebViewFinalizer(finalizer);
}

void Bindgen::Engine::bunBindgenEngine_webview_closeWebViewNative(
    const Bindgen::Engine::BunBindgenEngine_webview_closeWebViewNative_Arguments& args)
{
    args.view->closeNative(args.shutting_down);
}

void Bindgen::Engine::bunBindgenEngine_webview_shutdownWebViewTransports(
    const Bindgen::Engine::BunBindgenEngine_webview_shutdownWebViewTransports_Arguments& args)
{
    CDP::transport(*args.vm).shutdown();
#if OS(DARWIN)
    WK::client(*args.vm).shutdown();
#endif
}

void Bindgen::Engine::bunBindgenEngine_webview_resetWebViewTransports(
    const Bindgen::Engine::BunBindgenEngine_webview_resetWebViewTransports_Arguments& args)
{
    CDP::transport(*args.vm).reset();
#if OS(DARWIN)
    WK::client(*args.vm).reset();
#endif
}

// ---------------------------------------------------------------------------
// Shared weak owner. Both backends (WebKit's HostClient.viewsById and
// Chrome's Transport.m_views) hold Weak<JSWebView>. The
// isReachableFromOpaqueRoots predicate reads the atomic activity count:
// under `bun test` the closure → view → pendingNavigate → promise →
// reaction → closure cycle has no external root (the test-function promise
// goes out of Zig scope after runTestCallback returns). This IS the root.
// ---------------------------------------------------------------------------

class JSWebViewWeakOwner final : public JSC::WeakHandleOwner {
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, JSC::AbstractSlotVisitor& visitor, ASCIILiteral* reason) final
    {
        auto* view = uncheckedDowncast<JSWebView>(handle.slot()->asCell());
        if (visitor.containsOpaqueRoot(static_cast<WebCore::EventTarget*>(&view->wrapped()))) {
            if (reason) [[unlikely]]
                *reason = "Reachable from Event"_s;
            return true;
        }
        if (view->wrapped().m_pendingActivityCount.load(std::memory_order_acquire) == 0)
            return false;
        if (reason) [[unlikely]]
            *reason = "WebView with pending operation"_s;
        return true;
    }

    void finalize(JSC::Handle<JSC::Unknown> handle, void* context) final
    {
        if (!context)
            return;
        // Registered wrappers are EventTargets; their JS Structures may already be swept.
        auto* wrapper = static_cast<JSWebView::Base*>(handle.slot()->asCell());
        auto& target = wrapper->wrapped();
        RELEASE_ASSERT(target.eventTargetInterface() == WebCore::BunWebViewEventTargetInterfaceType);
        auto* view = static_cast<WebViewEventTarget*>(&target);
        auto& world = *static_cast<WebCore::DOMWrapperWorld*>(context);
        WebCore::uncacheWrapper(world, view, wrapper);
    }
};

WeakHandleOwner& webViewWeakOwner()
{
    static NeverDestroyed<JSWebViewWeakOwner> owner;
    return owner.get();
}

bool Bindgen::WebViewPredicates::isGlobalConsole(JSC::JSGlobalObject& global, JSC::JSValue value) noexcept
{
    auto* console = dynamicDowncast<JSC::ConsoleObject>(value);
    return console && console->realm() == &global;
}

// --- Pending-op slots -------------------------------------------------------

JSPromise* pendingOp(JSWebView* view, PendingOp op)
{
    JSValue value;
    switch (op) {
    case PendingOp::Navigate:
        value = view->raw_slot_pendingNavigate();
        break;
    case PendingOp::Evaluate:
        value = view->raw_slot_pendingEval();
        break;
    case PendingOp::Screenshot:
        value = view->raw_slot_pendingScreenshot();
        break;
    case PendingOp::Misc:
        value = view->raw_slot_pendingMisc();
        break;
    case PendingOp::Cdp:
        value = view->raw_slot_pendingCdp();
        break;
    }
    return value ? uncheckedDowncast<JSPromise>(value) : nullptr;
}

static void setPendingOpValue(VM& vm, JSWebView* view, PendingOp op, JSValue value)
{
    switch (op) {
    case PendingOp::Navigate:
        view->set_slot_pendingNavigate(vm, value);
        return;
    case PendingOp::Evaluate:
        view->set_slot_pendingEval(vm, value);
        return;
    case PendingOp::Screenshot:
        view->set_slot_pendingScreenshot(vm, value);
        return;
    case PendingOp::Misc:
        view->set_slot_pendingMisc(vm, value);
        return;
    case PendingOp::Cdp:
        view->set_slot_pendingCdp(vm, value);
        return;
    }
}

void setPendingOp(VM& vm, JSWebView* view, PendingOp op, JSPromise* promise)
{
    RELEASE_ASSERT(!pendingOp(view, op));
    view->wrapped().m_pendingActivityCount.fetch_add(1, std::memory_order_release);
    setPendingOpValue(vm, view, op, promise);
}

static JSPromise* takePendingOp(JSWebView* view, PendingOp op)
{
    auto* promise = pendingOp(view, op);
    if (!promise) return nullptr;
    setPendingOpValue(view->vm(), view, op, {});
    auto count = view->wrapped().m_pendingActivityCount.fetch_sub(1, std::memory_order_release);
    RELEASE_ASSERT(count);
    return promise;
}

void settleSlot(JSGlobalObject* g, JSWebView* v, PendingOp op, bool ok, JSValue value)
{
    auto* p = takePendingOp(v, op);
    if (!p) return;
    if (ok)
        p->resolve(g, g->vm(), value);
    else
        p->reject(g->vm(), value);
}

void rejectPendingOps(JSGlobalObject* global, JSWebView* view, JSValue reason)
{
    for (auto op : { PendingOp::Navigate, PendingOp::Evaluate, PendingOp::Screenshot, PendingOp::Misc, PendingOp::Cdp })
        settleSlot(global, view, op, false, reason);
}

void abandonPendingOps(JSWebView* view)
{
    for (auto op : { PendingOp::Navigate, PendingOp::Evaluate, PendingOp::Screenshot, PendingOp::Misc, PendingOp::Cdp })
        takePendingOp(view, op);
}

// --- Backend dispatch -------------------------------------------------------
// Each branches on the impl's backend. WebKit paths are Darwin-gated;
// calling one with backend=WebKit off-Darwin is unreachable (constructor
// already threw).

#if !OS(DARWIN)
#define WK_DISPATCH(call)             \
    do {                              \
        RELEASE_ASSERT_NOT_REACHED(); \
        return nullptr;               \
    } while (0)
#else
#define WK_DISPATCH(call) return call
#endif

static JSPromise* dispatchNavigate(JSGlobalObject* g, JSWebView* view, const WTF::String& url)
{
    auto& impl = view->wrapped();
    if (impl.m_backend == WebViewBackend::Chrome) {
        auto* p = CDP::Ops::navigate(g, view, url);
        if (pendingOp(view, PendingOp::Navigate)) impl.m_loading = true;
        return p;
    }
    WK_DISPATCH(WK::Ops::navigate(g, view, url));
}

static JSPromise* dispatchEvaluate(JSGlobalObject* g, JSWebView* view, const WTF::String& script)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome) return CDP::Ops::evaluate(g, view, script);
    WK_DISPATCH(WK::Ops::evaluate(g, view, script));
}

static JSPromise* dispatchScreenshot(JSGlobalObject* g, JSWebView* view, ScreenshotFormat format, uint8_t quality)
{
    view->wrapped().m_screenshotFormat = format;
    if (view->wrapped().m_backend == WebViewBackend::Chrome) return CDP::Ops::screenshot(g, view, format, quality);
    WK_DISPATCH(WK::Ops::screenshot(g, view, format, quality));
}

static JSPromise* dispatchClick(JSGlobalObject* g, JSWebView* view, float x, float y, uint8_t button, uint8_t modifiers, uint8_t clickCount)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome)
        return CDP::Ops::click(g, view, x, y, button, modifiers, clickCount);
    WK_DISPATCH(WK::Ops::click(g, view, x, y, button, modifiers, clickCount));
}

static JSPromise* dispatchClickSelector(JSGlobalObject* g, JSWebView* view, const WTF::String& selector, uint32_t timeout, uint8_t button, uint8_t modifiers, uint8_t clickCount)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome)
        return CDP::Ops::clickSelector(g, view, selector, timeout, button, modifiers, clickCount);
    WK_DISPATCH(WK::Ops::clickSelector(g, view, selector, timeout, button, modifiers, clickCount));
}

static JSPromise* dispatchType(JSGlobalObject* g, JSWebView* view, const WTF::String& text)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome) return CDP::Ops::type(g, view, text);
    WK_DISPATCH(WK::Ops::type(g, view, text));
}

static JSPromise* dispatchPress(JSGlobalObject* g, JSWebView* view, VirtualKey key, uint8_t modifiers, const WTF::String& character)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome)
        return CDP::Ops::press(g, view, static_cast<uint8_t>(key), modifiers, character);
    WK_DISPATCH(WK::Ops::press(g, view, key, modifiers, character));
}

static JSPromise* dispatchScroll(JSGlobalObject* g, JSWebView* view, double dx, double dy)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome) return CDP::Ops::scroll(g, view, dx, dy);
    WK_DISPATCH(WK::Ops::scroll(g, view, dx, dy));
}

static JSPromise* dispatchScrollTo(JSGlobalObject* g, JSWebView* view, const WTF::String& selector, uint32_t timeout, uint8_t block)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome)
        return CDP::Ops::scrollTo(g, view, selector, timeout, block);
    WK_DISPATCH(WK::Ops::scrollTo(g, view, selector, timeout, block));
}

static JSPromise* dispatchResize(JSGlobalObject* g, JSWebView* view, uint32_t width, uint32_t height)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome) return CDP::Ops::resize(g, view, width, height);
    WK_DISPATCH(WK::Ops::resize(g, view, width, height));
}

static JSPromise* dispatchGoBack(JSGlobalObject* g, JSWebView* view)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome) return CDP::Ops::goBack(g, view);
    WK_DISPATCH(WK::Ops::goBack(g, view));
}

static JSPromise* dispatchGoForward(JSGlobalObject* g, JSWebView* view)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome) return CDP::Ops::goForward(g, view);
    WK_DISPATCH(WK::Ops::goForward(g, view));
}

static JSPromise* dispatchReload(JSGlobalObject* g, JSWebView* view)
{
    if (view->wrapped().m_backend == WebViewBackend::Chrome) return CDP::Ops::reload(g, view);
    WK_DISPATCH(WK::Ops::reload(g, view));
}

// Chrome-only; the prototype implementation already threw for WebKit.
static JSPromise* dispatchCdpOp(JSGlobalObject* g, JSWebView* view, const WTF::String& method, const WTF::String& paramsJson)
{
    ASSERT(view->wrapped().m_backend == WebViewBackend::Chrome);
    return CDP::Ops::cdp(g, view, method, paramsJson);
}

#undef WK_DISPATCH

static void doClose(JSWebView* view)
{
    view->wrapped().m_closed = true;
    view->wrapped().m_loading = false;
    if (view->wrapped().m_backend == WebViewBackend::Chrome) {
        CDP::Ops::close(view);
        return;
    }
#if OS(DARWIN)
    WK::Ops::close(view);
#endif
}

// Chrome back/forward chains Page.getNavigationHistory →
// Page.navigateToHistoryEntry and settles via Page.loadEventFired, which
// only resolves PendingOp::Navigate. WebKit's Op::History Ack is sync
// (Misc). Same backend-dependent slot as reload.
static PendingOp navOp(JSWebView* view)
{
    return view->wrapped().m_backend == WebViewBackend::Chrome ? PendingOp::Navigate : PendingOp::Misc;
}

// --- Implementation helpers -------------------------------------------------

static bool checkOpen(JSGlobalObject* g, ThrowScope& scope, JSWebView* view, ASCIILiteral method)
{
    if (view->wrapped().m_closed) {
        Bun::ERR::INVALID_STATE(scope, g, makeString("WebView."_s, method, ": view is closed"_s));
        return false;
    }
    return true;
}

// Slot-empty check + INVALID_STATE. Separate from checkOpen because each
// method uses a different slot.
static bool checkIdle(JSGlobalObject* g, ThrowScope& scope, JSWebView* view, PendingOp op, ASCIILiteral what)
{
    if (pendingOp(view, op)) {
        Bun::ERR::INVALID_STATE(scope, g, makeString(what, " is already pending"_s));
        return false;
    }
    return true;
}

static uint8_t modifierMask(const std::optional<WTF::Vector<WTF::String>>& names)
{
    if (!names) return 0;
    uint8_t mods = 0;
    for (auto& s : *names) {
        if (s == "Shift"_s || s == "shift"_s)
            mods |= ModShift;
        else if (s == "Control"_s || s == "Ctrl"_s || s == "ctrl"_s || s == "control"_s)
            mods |= ModCtrl;
        else if (s == "Alt"_s || s == "alt"_s || s == "Option"_s || s == "option"_s)
            mods |= ModAlt;
        else if (s == "Meta"_s || s == "meta"_s || s == "Cmd"_s || s == "cmd"_s || s == "Command"_s || s == "command"_s)
            mods |= ModMeta;
    }
    return mods;
}

static uint8_t mouseButtonValue(std::optional<Bindgen::WebViewMouseButton> button)
{
    if (!button) return 0;
    switch (*button) {
    case Bindgen::WebViewMouseButton::left:
        return 0;
    case Bindgen::WebViewMouseButton::right:
        return 1;
    case Bindgen::WebViewMouseButton::middle:
        return 2;
    }
    return 0;
}

// JS string name → wire tag. Order must match ipc_protocol.h's enum; the
// static_assert in WebViewHost.cpp enforces the child-side table matches too.
static VirtualKey virtualKeyFromName(const WTF::String& s)
{
    struct {
        ASCIILiteral name;
        VirtualKey k;
    } table[] = {
        { "Enter"_s, VirtualKey::Enter },
        { "Tab"_s, VirtualKey::Tab },
        { "Space"_s, VirtualKey::Space },
        { "Backspace"_s, VirtualKey::Backspace },
        { "Delete"_s, VirtualKey::Delete },
        { "Escape"_s, VirtualKey::Escape },
        { "ArrowLeft"_s, VirtualKey::ArrowLeft },
        { "ArrowRight"_s, VirtualKey::ArrowRight },
        { "ArrowUp"_s, VirtualKey::ArrowUp },
        { "ArrowDown"_s, VirtualKey::ArrowDown },
        { "Home"_s, VirtualKey::Home },
        { "End"_s, VirtualKey::End },
        { "PageUp"_s, VirtualKey::PageUp },
        { "PageDown"_s, VirtualKey::PageDown },
    };
    for (auto& e : table)
        if (s == e.name) return e.k;
    return VirtualKey::Character;
}

} // namespace Bun

void Bun::closeAllWebViewsForTermination(VirtualMachine* vm)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_ChromeProcess_chromeProcessKill(vm);
    Bun::Bindgen::ZigExports::bunBindgenZig_WebViewHostProcess_webViewHostProcessKill(vm);
}

void Bun::Bindgen::Engine::bunBindgenEngine_webview_closeAllWebViewsForTermination(
    const Bun::Bindgen::Engine::BunBindgenEngine_webview_closeAllWebViewsForTermination_Arguments& args)
{
    Bun::closeAllWebViewsForTermination(args.vm);
}

// ---------------------------------------------------------------------------
// Generated-callback implementations.
// ---------------------------------------------------------------------------

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebViewProto;

JSWebView* bunBindgenCpp_webview_WebView_construct(
    CppEngineConstructContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_construct_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* zigGlobal = defaultGlobalObject(global);

    uint32_t width = 800, height = 600;
    WTF::String persistDir;
    WTF::String initialUrl;
    // Default: WebKit on Darwin (lighter than Chrome, always present);
    // Chrome elsewhere (WebKit needs the system framework, Darwin-only).
#if OS(DARWIN)
    WebViewBackend backend = WebViewBackend::WebKit;
#else
    WebViewBackend backend = WebViewBackend::Chrome;
#endif
    WTF::String chromePath;
    WTF::String chromeWsUrl;
    bool chromeSkipAutoDetect = false;
    WTF::Vector<WTF::String> chromeArgv;
    bool stdoutInherit = false;
    bool stderrInherit = false;
    bool consoleIsGlobal = false;
    JSObject* consoleCallback = nullptr;

    if (args.options) {
        auto& opts = *args.options;
        width = opts.width;
        height = opts.height;
        if (opts.headless && !*opts.headless) {
            Bun::throwError(global, scope, ErrorCode::ERR_METHOD_NOT_IMPLEMENTED,
                "headless: false is not yet implemented"_s);
            return nullptr;
        }
        if (opts.backend) {
            auto& be = *opts.backend;
            if (be.is_kind()) {
                backend = be.kind() == WebViewBackendKind::chrome
                    ? WebViewBackend::Chrome
                    : WebViewBackend::WebKit;
            } else if (be.is_options()) {
                auto& beOpts = be.options();
                backend = beOpts.type == WebViewBackendKind::chrome
                    ? WebViewBackend::Chrome
                    : WebViewBackend::WebKit;
                if (beOpts.path) chromePath = *beOpts.path;

                // url: controls the connect-vs-spawn choice.
                //   - "ws://..." — connect to that DevTools WebSocket directly
                //   - false — skip DevToolsActivePort auto-detect, always spawn
                //     (executable path still auto-found if `path` unset)
                //   - undefined (default) — auto-detect: if DevToolsActivePort
                //     exists, connect to the existing Chrome; else spawn
                // Bare host:port isn't accepted — Chrome's new chrome://inspect
                // toggle 404s /json/version so there's no HTTP discovery path;
                // the file IS the discovery source.
                if (beOpts.url) {
                    if (beOpts.url->is_url()) {
                        if (backend != WebViewBackend::Chrome) {
                            Bun::throwError(global, scope, ErrorCode::ERR_INVALID_ARG_VALUE,
                                "backend.url requires type: \"chrome\""_s);
                            return nullptr;
                        }
                        chromeWsUrl = beOpts.url->url();
                        if (!chromeWsUrl.startsWith("ws://"_s) && !chromeWsUrl.startsWith("wss://"_s)) {
                            Bun::throwError(global, scope, ErrorCode::ERR_INVALID_ARG_VALUE,
                                "backend.url must be a ws:// URL (read DevToolsActivePort from Chrome's profile dir, "
                                "or omit url to auto-detect)"_s);
                            return nullptr;
                        }
                    } else if (!beOpts.url->flag()) {
                        chromeSkipAutoDetect = true;
                    } else {
                        Bun::throwError(global, scope, ErrorCode::ERR_INVALID_ARG_TYPE,
                            "backend.url must be a ws:// string or false"_s);
                        return nullptr;
                    }
                }

                if (beOpts.argv) chromeArgv = *beOpts.argv;

                if (!chromeWsUrl.isEmpty() && (!chromePath.isEmpty() || !chromeArgv.isEmpty())) {
                    Bun::throwError(global, scope, ErrorCode::ERR_INVALID_ARG_VALUE,
                        "backend.url (connect mode) cannot be combined with backend.path or backend.argv (spawn mode)"_s);
                    return nullptr;
                }

                // stdout/stderr: whether the subprocess's streams flow to
                // Bun's. Chrome is chatty on stderr (GCM registration errors,
                // updater noise, font-config warnings) even with our flag
                // suite; default ignore keeps test output clean. "inherit" is
                // useful when Chrome crashes silently (the crash report goes
                // to stderr). stdout is mostly quiet for both backends — the
                // WebKit host only prints on panic.
                stdoutInherit = beOpts.stdout_mode == WebViewStdoutMode::inherit;
                stderrInherit = beOpts.stderr_mode == WebViewStderrMode::inherit;
            }
        }

        if (opts.url) initialUrl = *opts.url;

        // console: the current realm's console → direct ConsoleClient dispatch (no
        // JS call per console.log). console: (type, ...args) => {} → custom
        // callback. Passing the realm's intrinsic console object is the
        // opt-in signal.
        if (opts.console) {
            consoleIsGlobal = opts.console->is_global_console();
            if (opts.console->is_callback())
                consoleCallback = opts.console->callback().getObject();
        }

        if (opts.dataStore && opts.dataStore->is_options()) {
            persistDir = opts.dataStore->options().directory;
        }
    }

    if (backend == WebViewBackend::Chrome) {
        Bun::Bindgen::ZigExports::bunBindgenZig_Analytics_recordWebViewChrome();
        auto& t = CDP::transport(vm);

        // Transport selection, in priority order:
        //   1. url: "ws://..." → connect (autoDetected=false → no fallback)
        //   2. path/argv set OR url:false → spawn, skip auto-detect
        //   3. neither → auto-detect DevToolsActivePort → connect OR spawn
        //
        // All paths end up in the same singleton; first call wins. A stale
        // DevToolsActivePort (Chrome crashed/restarted) triggers the
        // wsOnClose fallback to spawn (autoDetected=true). The file read is
        // sync/instant so the constructor stays synchronous.
        bool ok;
        if (!chromeWsUrl.isEmpty()) {
            ok = t.ensureConnected(zigGlobal, chromeWsUrl, /* autoDetected */ false);
        } else if (chromeSkipAutoDetect || !chromePath.isEmpty() || !chromeArgv.isEmpty()) {
            ok = t.ensureSpawned(zigGlobal, persistDir, chromePath, chromeArgv, stdoutInherit, stderrInherit);
        } else {
            // Auto-detect. DevToolsActivePort URL caps at
            // ws://127.0.0.1:65535/devtools/browser/<36-char-uuid> ≈ 70B.
            char buf[128];
            size_t len = Bindgen::ZigExports::bunBindgenZig_ChromeProcess_chromeProcessAutoDetect(
                std::span<uint8_t> { reinterpret_cast<uint8_t*>(buf), sizeof(buf) });
            if (len > 0) {
                ok = t.ensureConnected(zigGlobal,
                    WTF::String::fromUTF8(std::span<const char>(buf, len)),
                    /* autoDetected */ true, persistDir, stdoutInherit, stderrInherit);
            } else {
                ok = t.ensureSpawned(zigGlobal, persistDir, chromePath, chromeArgv, stdoutInherit, stderrInherit);
            }
        }
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!ok) {
            Bun::throwError(global, scope, ErrorCode::ERR_DLOPEN_FAILED,
                chromeWsUrl.isEmpty()
                    ? "Failed to spawn Chrome (set BUN_CHROME_PATH, backend.path, or install Chrome/Chromium)"_s
                    : "Failed to connect to Chrome (check backend.url is a valid ws:// debugger endpoint)"_s);
            return nullptr;
        }

        auto impl = WebViewEventTarget::create(*zigGlobal->scriptExecutionContext());
        if (!impl) {
            throwOutOfMemoryError(global, scope);
            return nullptr;
        }
        impl->m_backend = WebViewBackend::Chrome;
        impl->m_connectionGeneration = t.m_connectionGeneration;
        impl->m_width = width;
        impl->m_height = height;
        impl->m_consoleIsGlobal = consoleIsGlobal;
        JSWebView* view = JSWebView::create(ctx.structure, zigGlobal, impl.releaseNonNull());
        // Wire impl→wrapper so event.target and the routing tables resolve.
        // The Weak's owner is the activity-count predicate.
        WebCore::cacheWrapper(zigGlobal->world(), &view->wrapped(), view);
        // One Weak per view, stored in Transport::m_views. All CDP routing
        // dereferences through this — m_pending and m_sessions hold just the
        // viewId, not their own Weaks. Mirrors WebKit's HostClient::viewsById.
        view->wrapped().m_viewId = t.registerView(view);
        if (consoleCallback) view->set_slot_onConsole(vm, consoleCallback);
        // Target.createTarget deferred to the first navigate() — keeps the
        // constructor synchronous and the attach chain owned by the navigate
        // promise (which resolves on Page.loadEventFired, so one await
        // covers the whole sequence).
        if (!initialUrl.isEmpty()) {
            dispatchNavigate(global, view, initialUrl);
            RETURN_IF_EXCEPTION(scope, nullptr);
        }
        return view;
    }

#if !OS(DARWIN)
    Bun::throwError(global, scope, ErrorCode::ERR_METHOD_NOT_IMPLEMENTED,
        "Bun.WebView with backend \"webkit\" is only available on macOS; use backend: \"chrome\""_s);
    return nullptr;
#else
    Bun::Bindgen::ZigExports::bunBindgenZig_Analytics_recordWebViewWebKit();
    auto& c = WK::client(vm);
    bool spawned = c.ensureSpawned(zigGlobal, stdoutInherit, stderrInherit);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!spawned) {
        Bun::throwError(global, scope, ErrorCode::ERR_DLOPEN_FAILED,
            "Failed to spawn WebView host process"_s);
        return nullptr;
    }

    bool persistent = !persistDir.isEmpty();
    auto payload = encode(
        CreatePayload { width, height,
            static_cast<uint8_t>(persistent ? DataStoreKind::Persistent : DataStoreKind::Ephemeral) },
        persistent ? persistDir : WTF::String());
    if (!payload) {
        scope.release();
        WK::throwPayloadError(global, payload.error());
        return nullptr;
    }

    auto impl = WebViewEventTarget::create(*zigGlobal->scriptExecutionContext());
    if (!impl) {
        throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    impl->m_consoleIsGlobal = consoleIsGlobal;
    impl->m_connectionGeneration = c.connectionGeneration;
    JSWebView* view = JSWebView::create(ctx.structure, zigGlobal, impl.releaseNonNull());
    WebCore::cacheWrapper(zigGlobal->world(), &view->wrapped(), view);
    view->wrapped().m_viewId = c.nextViewId++;
    c.viewsById.emplace(view->wrapped().m_viewId, JSC::Weak<JSWebView>(view, &webViewWeakOwner()));
    c.updateKeepAlive();

    if (!c.writeFrame(Op::Create, view->wrapped().m_viewId, payload->span().data(), payload->size())) {
        RETURN_IF_EXCEPTION(scope, nullptr);
        throwTypeError(global, scope, "Failed to send WebView creation request"_s);
        return nullptr;
    }

    if (consoleCallback) view->set_slot_onConsole(vm, consoleCallback);
    // Navigate promise lands in the Navigate slot; the user's first await
    // (including the next navigate()) serializes behind it. If it rejects
    // (bad URL), the next op's checkIdle sees the slot cleared and proceeds;
    // the rejection is unobserved unless the user explicitly awaits the
    // first navigate via view.onNavigated or a second navigate that picks
    // up the pending state. Same semantics as `view.navigate(url)` right
    // after construction — just one line shorter.
    if (!initialUrl.isEmpty()) {
        dispatchNavigate(global, view, initialUrl);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    return view;
#endif
}

JSValue bunBindgenCpp_webview_WebView_method_navigate(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_navigate_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "navigate"_s)) return {};
    if (!checkIdle(global, scope, view, PendingOp::Navigate, "a navigation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchNavigate(global, view, args.url));
}

JSValue bunBindgenCpp_webview_WebView_method_evaluate(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_evaluate_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "evaluate"_s)) return {};
    if (!checkIdle(global, scope, view, PendingOp::Evaluate, "an evaluate()"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchEvaluate(global, view, args.script));
}

JSValue bunBindgenCpp_webview_WebView_method_screenshot(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_screenshot_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "screenshot"_s)) return {};

    ScreenshotFormat format = ScreenshotFormat::Png;
    ScreenshotEncoding encoding = ScreenshotEncoding::Blob;
    uint8_t quality = 80; // CDP default for jpeg/webp. Ignored for png.

    if (args.options) {
        auto& opts = *args.options;
        if (opts.format) {
            switch (*opts.format) {
            case WebViewScreenshotFormat::png:
                format = ScreenshotFormat::Png;
                break;
            case WebViewScreenshotFormat::jpeg:
                format = ScreenshotFormat::Jpeg;
                break;
            case WebViewScreenshotFormat::webp:
                // NSBitmapImageRep's representationUsingType: has no WebP
                // enum value — would need ImageIO's CGImageDestination with
                // public.webp UTI (macOS 11+), which is a separate dlsym
                // surface not yet wired. Chrome-only until then.
                if (view->wrapped().m_backend != WebViewBackend::Chrome) {
                    Bun::throwError(global, scope, ErrorCode::ERR_METHOD_NOT_IMPLEMENTED,
                        "format: \"webp\" requires backend: \"chrome\""_s);
                    return {};
                }
                format = ScreenshotFormat::Webp;
                break;
            }
        }
        quality = opts.quality;
        if (opts.encoding) {
            switch (*opts.encoding) {
            case WebViewScreenshotEncoding::blob:
                encoding = ScreenshotEncoding::Blob;
                break;
            case WebViewScreenshotEncoding::buffer:
                encoding = ScreenshotEncoding::Buffer;
                break;
            case WebViewScreenshotEncoding::base64:
                encoding = ScreenshotEncoding::Base64;
                break;
            case WebViewScreenshotEncoding::shmem:
                // encoding: "shmem" is for Kitty graphics protocol t=s —
                // returns {name, size}, we skip our shm_unlink, the terminal
                // handles cleanup.
#if OS(WINDOWS)
                // No POSIX shm. Kitty on Windows uses temp files (t=t)
                // or direct (t=d) transmission anyway.
                Bun::throwError(global, scope, ErrorCode::ERR_METHOD_NOT_IMPLEMENTED,
                    "encoding: \"shmem\" is not supported on Windows"_s);
                return {};
#else
                encoding = ScreenshotEncoding::Shmem;
                break;
#endif
            }
        }
    }

    if (!checkIdle(global, scope, view, PendingOp::Screenshot, "a screenshot()"_s)) return {};
    view->wrapped().m_screenshotEncoding = encoding;
    RELEASE_AND_RETURN(scope, dispatchScreenshot(global, view, format, quality));
}

// Raw Chrome DevTools Protocol escape hatch. view.cdp("Domain.method",
// {params}) → JSON.parse(response.result). Chrome-only: WebKit's host
// subprocess speaks a binary frame protocol, not CDP.
//
// params is JSON.stringify'd here and inserted verbatim into the CDP
// envelope. JSONStringify rejects cycles and non-serializable values with
// a TypeError — same as `JSON.stringify(params)` in user code.
//
// The command carries this view's sessionId, so it targets THIS tab.
// Domain-qualified: "Page.captureScreenshot", "Runtime.evaluate", etc. Not
// validated here — Chrome returns a {"code":-32601} error which rejects
// the promise.
JSValue bunBindgenCpp_webview_WebView_method_cdp(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_cdp_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "cdp"_s)) return {};

    if (view->wrapped().m_backend != WebViewBackend::Chrome) {
        Bun::throwError(global, scope, ErrorCode::ERR_METHOD_NOT_IMPLEMENTED,
            "WebView.cdp() requires backend: \"chrome\""_s);
        return {};
    }

    // Must have attached (first navigate() completes the target→session
    // chain). Before attach there's no sessionId; a browser-level CDP
    // command here would reach the wrong target.
    if (view->wrapped().m_sessionId.isEmpty()) {
        Bun::ERR::INVALID_STATE(scope, global, "WebView.cdp(): no session - await navigate() first"_s);
        return {};
    }

    WTF::String paramsJson = "{}"_s;
    if (args.params) {
        const auto* convertedParams = args.params->convert();
        RETURN_IF_EXCEPTION(scope, {});
        if (!convertedParams)
            return {};
        if (convertedParams->is_invalid()) {
            Bun::throwError(global, scope, ErrorCode::ERR_INVALID_ARG_TYPE,
                "params must be a JSON-serializable object"_s);
            return {};
        }
        if (convertedParams->is_object()) {
            paramsJson = JSONStringify(global, convertedParams->object(), 0);
            RETURN_IF_EXCEPTION(scope, {});
            if (paramsJson.isEmpty() || paramsJson[0] != '{') {
                Bun::throwError(global, scope, ErrorCode::ERR_INVALID_ARG_TYPE,
                    "params must be a JSON-serializable object"_s);
                return {};
            }
        }
    }

    // JSONStringify can call a user-supplied .toJSON() that closes the view
    // between the earlier guards and send.
    if (view->wrapped().m_closed) {
        Bun::throwError(global, scope, ErrorCode::ERR_INVALID_STATE, "WebView is closed"_s);
        return {};
    }
    if (!checkIdle(global, scope, view, PendingOp::Cdp, "a cdp()"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchCdpOp(global, view, args.method, paramsJson));
}

JSValue bunBindgenCpp_webview_WebView_method_click_overload_selector(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_click_overload_selector_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "click"_s)) return {};
    if (args.selector.isEmpty()) {
        Bun::ERR::INVALID_ARG_VALUE(scope, global, "selector"_s, jsString(JSC::getVM(global), args.selector), "must not be empty"_s);
        return {};
    }
    uint8_t button = 0, mods = 0, clickCount = 1;
    uint32_t timeout = 30000;
    if (args.options) {
        button = mouseButtonValue(args.options->button);
        mods = modifierMask(args.options->modifiers);
        clickCount = static_cast<uint8_t>(args.options->clickCount);
        timeout = args.options->timeout;
    }
    if (!checkIdle(global, scope, view, PendingOp::Misc, "a simple operation"_s)) return {};
    // rAF-polled actionability check page-side, then native click at the
    // resolved center.
    RELEASE_AND_RETURN(scope, dispatchClickSelector(global, view, args.selector, timeout, button, mods, clickCount));
}

JSValue bunBindgenCpp_webview_WebView_method_click_overload_point(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_click_overload_point_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "click"_s)) return {};
    uint8_t button = 0, mods = 0, clickCount = 1;
    if (args.options) {
        button = mouseButtonValue(args.options->button);
        mods = modifierMask(args.options->modifiers);
        clickCount = static_cast<uint8_t>(args.options->clickCount);
    }
    if (!checkIdle(global, scope, view, PendingOp::Misc, "a simple operation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchClick(global, view,
        static_cast<float>(args.x), static_cast<float>(args.y), button, mods, clickCount));
}

JSValue bunBindgenCpp_webview_WebView_method_type(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_type_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "type"_s)) return {};
    if (!checkIdle(global, scope, view, PendingOp::Misc, "a simple operation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchType(global, view, args.text));
}

JSValue bunBindgenCpp_webview_WebView_method_press(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_press_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "press"_s)) return {};

    uint8_t mods = args.options ? modifierMask(args.options->modifiers) : 0;
    VirtualKey vk = virtualKeyFromName(args.key);
    if (vk == VirtualKey::Character && args.key.length() != 1) {
        Bun::ERR::INVALID_ARG_VALUE(scope, global, "key"_s, jsString(vm, args.key),
            "must be a virtual key name (Enter, Tab, Escape, Arrow*, etc.) or a single character"_s);
        return {};
    }

    if (!checkIdle(global, scope, view, PendingOp::Misc, "a simple operation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchPress(global, view, vk, mods,
        vk == VirtualKey::Character ? args.key : WTF::String()));
}

JSValue bunBindgenCpp_webview_WebView_method_scroll(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_scroll_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "scroll"_s)) return {};
    if (!checkIdle(global, scope, view, PendingOp::Misc, "a simple operation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchScroll(global, view, args.dx, args.dy));
}

JSValue bunBindgenCpp_webview_WebView_method_scrollTo(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_scrollTo_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "scrollTo"_s)) return {};
    if (args.selector.isEmpty()) {
        Bun::ERR::INVALID_ARG_VALUE(scope, global, "selector"_s, jsString(vm, args.selector), "must not be empty"_s);
        return {};
    }
    uint32_t timeout = 30000;
    uint8_t block = 1; // center
    if (args.options) {
        timeout = args.options->timeout;
        if (args.options->block) {
            switch (*args.options->block) {
            case WebViewScrollBlock::start:
                block = 0;
                break;
            case WebViewScrollBlock::center:
                block = 1;
                break;
            case WebViewScrollBlock::end:
                block = 2;
                break;
            case WebViewScrollBlock::nearest:
                block = 3;
                break;
            }
        }
    }
    if (!checkIdle(global, scope, view, PendingOp::Misc, "a simple operation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchScrollTo(global, view, args.selector, timeout, block));
}

JSValue bunBindgenCpp_webview_WebView_method_resize(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_resize_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "resize"_s)) return {};
    if (!checkIdle(global, scope, view, PendingOp::Misc, "a simple operation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchResize(global, view, args.width, args.height));
}

JSValue bunBindgenCpp_webview_WebView_method_goBack(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_goBack_Arguments&)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "goBack"_s)) return {};
    if (!checkIdle(global, scope, view, navOp(view), "a navigation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchGoBack(global, view));
}

JSValue bunBindgenCpp_webview_WebView_method_goForward(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_goForward_Arguments&)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "goForward"_s)) return {};
    if (!checkIdle(global, scope, view, navOp(view), "a navigation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchGoForward(global, view));
}

JSValue bunBindgenCpp_webview_WebView_method_reload(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_reload_Arguments&)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* view = &ctx.wrapper;
    if (!checkOpen(global, scope, view, "reload"_s)) return {};
    if (!checkIdle(global, scope, view, navOp(view), "a navigation"_s)) return {};
    RELEASE_AND_RETURN(scope, dispatchReload(global, view));
}

// close() is synchronous: writes the Close frame, rejects any pending
// promises, erases from the routing table. `using` calls dispose;
// `await using` calls asyncDispose — both alias this. No async teardown
// to wait for. Closing twice is a no-op.
static void closeImpl(JSWebView* view)
{
    if (view->wrapped().m_closed) return;
    doClose(view);
}

void bunBindgenCpp_webview_WebView_method_close(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_close_Arguments&)
{
    closeImpl(&ctx.wrapper);
}

void bunBindgenCpp_webview_WebView_method_closeDispose(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_closeDispose_Arguments&)
{
    closeImpl(&ctx.wrapper);
}

void bunBindgenCpp_webview_WebView_method_closeAsyncDispose(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_method_closeAsyncDispose_Arguments&)
{
    closeImpl(&ctx.wrapper);
}

WTF::String bunBindgenCpp_webview_WebView_getter_url(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_getter_url_Arguments&)
{
    return ctx.wrapped().m_url;
}

WTF::String bunBindgenCpp_webview_WebView_getter_title(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_getter_title_Arguments&)
{
    return ctx.wrapped().m_title;
}

bool bunBindgenCpp_webview_WebView_getter_loading(
    CppEngineCallContext<JSWebView>& ctx,
    const BunBindgenCpp_webview_WebView_getter_loading_Arguments&)
{
    return ctx.wrapped().m_loading;
}

void bunBindgenCpp_webview_WebView_static_method_closeAll(
    CppCallContext& context,
    const BunBindgenCpp_webview_WebView_static_method_closeAll_Arguments&)
{
    auto& vm = context.globalObject.vm();
    CDP::transport(vm).closeAll();
#if OS(DARWIN)
    WK::client(vm).rejectAllAndMarkDead("WebView host killed by WebView.closeAll()"_s);
#endif
    closeAllWebViewsForTermination(bunVM(vm));
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
