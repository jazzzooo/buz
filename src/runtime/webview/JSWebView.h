#pragma once

// Glue over the generated WebView wrapper cell. The cell class, prototype,
// constructor, and argument conversion all come from WebView.schema.zig; this
// header names the cell for the backends and declares the slot and rooting
// helpers shared by both of them.

#include "root.h"
#include "SchemaBindingsEngineClasses.h"
#include "WebViewEventTarget.h"
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/WeakHandleOwner.h>

namespace Bun {

using JSWebView = BunBindgen_webview_WebView;

// One wrapper slot per operation type. The backend request maps carry no JS
// refs — just {req_id → viewId, op}. If GC collects the wrapper (user
// dropped both view and the awaited promise), the reply finds a dead Weak
// and drops. No Strong<> roots.
enum class PendingOp : uint8_t {
    Navigate,
    Evaluate,
    Screenshot,
    // Resize/Back/Forward/Reload/Close — one at a time, the child is fast.
    Misc,
    // Chrome-only: raw view.cdp(method, params) escape hatch. Separate
    // slot so it doesn't block resize/goBack. Still one raw op at a time.
    Cdp,
};

JSC::JSPromise* pendingOp(JSWebView*, PendingOp);

// Store the promise and bump the activity count that roots the wrapper.
void setPendingOp(JSC::VM&, JSWebView*, PendingOp, JSC::JSPromise*);

// Settle = read, clear, dec activity, resolve-or-reject. Slot cleared BEFORE
// the call into JS so a re-entrant navigate() inside a .then() sees an empty
// slot. Activity decremented AFTER clear (GC seeing count>0 with a clear
// slot is benign — one extra mark cycle). Shared by all backends.
void settleSlot(JSC::JSGlobalObject*, JSWebView*, PendingOp, bool ok, JSC::JSValue);
void rejectPendingOps(JSC::JSGlobalObject*, JSWebView*, JSC::JSValue);
void abandonPendingOps(JSWebView*);

// Shared weak owner for HostClient.viewsById and Transport.m_views. Roots a
// view while its impl's m_pendingActivityCount > 0. Also the wrapper's
// ScriptWrappable owner, set at construction; the generated engine toJS
// used by generated event.target conversion.
JSC::WeakHandleOwner& webViewWeakOwner();

void closeAllWebViewsForTermination(VirtualMachine*);

} // namespace Bun
