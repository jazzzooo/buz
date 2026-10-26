#include "config.h"
#include "JSAbortController.h"

#include "AbortController.h"
#include "AbortControllerOwner.h"
#include "JSAbortSignal.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "ScriptExecutionContext.h"
#include "WebCoreOpaqueRootInlines.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/SlotVisitorMacros.h>

namespace WebCore {

bool JSAbortControllerOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void*, JSC::AbstractSlotVisitor&, ASCIILiteral*)
{
    return false;
}

void JSAbortControllerOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSAbortController*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {

using namespace JSC;
using namespace WebCore;

template<typename Visitor>
void BunBindgen_WebCoreEvents_AbortController::visitAdditionalChildren(Visitor& visitor)
{
    addWebCoreOpaqueRoot(visitor, wrapped().opaqueRoot());
    wrapped().signal().reason().visit(visitor);
}

template void BunBindgen_WebCoreEvents_AbortController::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCoreEvents_AbortController::visitAdditionalChildren(JSC::SlotVisitor&);

namespace Bindgen {
namespace Cpp {

JSAbortController* bunBindgenCpp_WebCoreEvents_AbortController_construct(
    CppEngineConstructContext<JSAbortController>& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortController_construct_Arguments&)
{
    auto* global = &ctx.globalObject;
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* zigGlobal = defaultGlobalObject(global);
    auto* context = zigGlobal->scriptExecutionContext();
    if (!context) [[unlikely]] {
        throwConstructorScriptExecutionContextUnavailableError(*global, scope, "AbortController"_s);
        return nullptr;
    }
    auto impl = AbortController::create(*context);
    auto* implPtr = impl.ptr();
    auto* wrapper = JSAbortController::create(ctx.structure, zigGlobal, WTF::move(impl));
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    return wrapper;
}

JSValue bunBindgenCpp_WebCoreEvents_AbortController_getter_signal(
    CppEngineCallContext<JSAbortController>& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortController_getter_signal_Arguments&)
{
    return toJS(&ctx.globalObject, defaultGlobalObject(&ctx.globalObject), ctx.wrapped().signal());
}

void bunBindgenCpp_WebCoreEvents_AbortController_method_abort(
    CppEngineCallContext<JSAbortController>& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortController_method_abort_Arguments& args)
{
    auto* zigGlobal = defaultGlobalObject(&ctx.globalObject);
    ctx.wrapped().abort(*zigGlobal, args.reason.value_or(jsUndefined()));
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
