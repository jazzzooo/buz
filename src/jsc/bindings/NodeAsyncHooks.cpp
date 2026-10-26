#include "config.h"

#include "SchemaBindings.h"
#include "JavaScriptCore/JSObject.h"
#include "JavaScriptCore/ObjectConstructor.h"
#include "JavaScriptCore/ArrayConstructor.h"

#include "ZigGlobalObject.h"

namespace Bun {

using namespace JSC;

// `cleanupLayer` is called by js if we set async context in a way we may not
// clear it, specifically within AsyncLocalStorage.prototype.enterWith.  this
// function will not clear the async context until the next tick's microtask,
// where it must inherit the context that scheduled that callback.
void Bindgen::Cpp::bunBindgenCpp_AsyncHooks_cleanupLater(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_AsyncHooks_cleanupLater_Arguments&)
{
    auto* global = uncheckedDowncast<::Zig::GlobalObject>(&context.globalObject);
    global->asyncHooksNeedsCleanup = true;
    global->resetOnEachMicrotaskTick();
}

// This is called when AsyncLocalStorage is constructed.
void Bindgen::Cpp::bunBindgenCpp_AsyncHooks_setAsyncHooksEnabled(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_AsyncHooks_setAsyncHooksEnabled_Arguments& args)
{
    context.globalObject.setAsyncContextTrackingEnabled(args.enabled);
}

}
