#pragma once

// The WebView native: an EventTarget impl owned by the generated wrapper's
// Ref<Impl>. It holds the listener map plus all engine-independent WebView
// state; JS-value state (pending promises, handler callbacks) lives in the
// generated wrapper's cached slots, which GC visits.
//
// Event targets resolve through the realm's weak wrapper cache. Backend
// routing tables separately retain weak references to operation receivers.

#include "root.h"
#include "ContextDestructionObserver.h"
#include "EventTarget.h"
#include "EventTargetInterfaces.h"
#include "ScriptExecutionContext.h"
#include <wtf/RefCounted.h>
#include <wtf/text/WTFString.h>
#include <atomic>

namespace JSC {
class WeakHandleOwner;
}

namespace WebCore {
class DOMWrapperWorld;
}

namespace Bun {

enum class WebViewBackend : uint8_t {
    WebKit, // WKWebView via separate host process (Darwin only)
    Chrome, // Chrome DevTools Protocol via --remote-debugging-pipe
};

enum class ScreenshotFormat : uint8_t {
    Png, // lossless, default.
    Jpeg, // lossy, quality 0-100.
    Webp, // lossy/lossless by quality. Chrome via CDP format:"webp";
          // WebKit via CGImageDestination with public.webp UTI (macOS 11+).
};

// How the image bytes are handed back to JS. The child (WebKit host,
// Chrome) always produces encoded image bytes; only the parent-side
// post-receive handling differs.
enum class ScreenshotEncoding : uint8_t {
    Blob, // default. WebKit: mmap'd shm → Blob store (zero-copy).
          // Chrome: base64-decode → Blob.
    Buffer, // WebKit: mmap'd shm → ArrayBuffer with munmap destructor
            // (zero-copy — same mapping as Blob, just wrapped as a
            // JSUint8Array Buffer). Chrome: base64-decode → Buffer.
    Base64, // WebKit: mmap → base64Encode → string, munmap.
            // Chrome: return the CDP "data" field as-is (zero decode).
    Shmem, // POSIX shm name + size. Parent does NOT shm_unlink —
           // caller (or Kitty via its t=s transmission mode) owns
           // cleanup. WebKit: the child already wrote here; just skip
           // our unlink. Chrome: create a fresh shm, write decoded
           // bytes, return name. Not supported on Windows.
};

inline const char* screenshotMimeType(ScreenshotFormat f)
{
    switch (f) {
    case ScreenshotFormat::Png:
        return "image/png";
    case ScreenshotFormat::Jpeg:
        return "image/jpeg";
    case ScreenshotFormat::Webp:
        return "image/webp";
    }
    return "image/png";
}

struct WebViewFinalizer;

class WebViewEventTarget final : public RefCounted<WebViewEventTarget>,
                                 public WebCore::EventTargetWithInlineData,
                                 private WebCore::ContextDestructionObserver {
    WTF_MAKE_TZONE_ALLOCATED(WebViewEventTarget);

public:
    static RefPtr<WebViewEventTarget> create(WebCore::ScriptExecutionContext&);
    ~WebViewEventTarget();

    void deref() const;
    using RefCounted::ref;
    void closeNative(bool shuttingDown = false);

    WebViewBackend m_backend = WebViewBackend::WebKit;

    // WebKit: viewId routes frames to the host. Chrome: transport view key.
    uint32_t m_viewId = 0;
    uint64_t m_connectionGeneration = 0;
    // Chrome: target creation width/height for the first navigate() which
    // does Target.createTarget. WebKit: held in the child.
    uint32_t m_width = 0, m_height = 0;
    bool m_closed = false;
    // Updated from NavDone replies / Page.frameNavigated — the getters are
    // synchronous but the real values live in the child.
    WTF::String m_url;
    WTF::String m_title;
    bool m_loading = false;

    // Chrome session state. Empty until the Target.createTarget →
    // Target.attachToTarget → Page.enable chain completes (driven by the
    // first navigate()). sessionId routes commands; targetId is for
    // Target.closeTarget. The chain stashes the navigate URL here so the
    // final step can send Page.navigate; subsequent navigates read
    // m_sessionId directly and skip the chain.
    WTF::String m_sessionId;
    WTF::String m_targetId;
    WTF::String m_pendingChromeNavigateUrl;
    // clickSelector stash — the actionability eval chains into a
    // dispatchMouseEvent that needs these. WebViewHost has the same fields
    // on its side (m_selButton etc.) for the same chain.
    uint8_t m_selButton = 0;
    uint8_t m_selModifiers = 0;
    uint8_t m_selClickCount = 1;
    // goBack/goForward stash — PageGetNavigationHistory chains into
    // navigateToHistoryEntry with entries[currentIndex + delta].id.
    int8_t m_chromeHistoryDelta = 0;
    // Screenshot format/encoding stash — set by screenshot() before
    // dispatch, read by both backends' response handlers. CDP/IPC payloads
    // don't echo these; stashing here is simpler than threading them
    // through Pending/viewId routing. format → MIME type on the Blob;
    // encoding → how the bytes are wrapped (Blob/Buffer/base64/shmem).
    ScreenshotFormat m_screenshotFormat = ScreenshotFormat::Png;
    ScreenshotEncoding m_screenshotEncoding = ScreenshotEncoding::Blob;

    // Console capture. If the user passed the current realm's console,
    // m_consoleIsGlobal is set and dispatch goes straight to the native
    // console sink — no JS call. Otherwise the wrapper's onConsole slot
    // holds a (type, ...args) callback.
    bool m_consoleIsGlobal = false;

    // Read by isReachableFromOpaqueRoots on the GC thread — the wrapper's
    // slot barriers are not safe to read there. Inc BEFORE slot set, dec
    // AFTER slot clear, so GC never sees a set slot with count==0.
    std::atomic<uint32_t> m_pendingActivityCount { 0 };

private:
    WebViewEventTarget(WebCore::ScriptExecutionContext& ctx, WebViewFinalizer* finalizer)
        : ContextDestructionObserver(&ctx)
        , m_vm(ctx.vm())
        , m_finalizer(finalizer)
    {
    }

    WebCore::EventTargetInterface eventTargetInterface() const final { return WebCore::BunWebViewEventTargetInterfaceType; }
    WebCore::ScriptExecutionContext* scriptExecutionContext() const final { return ContextDestructionObserver::scriptExecutionContext(); }

    void refEventTarget() final { ref(); }
    void derefEventTarget() final { deref(); }
    JSC::VM& m_vm;
    mutable WebViewFinalizer* m_finalizer;
    bool m_backendReleased { false };
};

JSC::WeakHandleOwner& webViewWeakOwner();

inline JSC::WeakHandleOwner* wrapperOwner(WebCore::DOMWrapperWorld&, WebViewEventTarget*)
{
    return &webViewWeakOwner();
}

} // namespace Bun
