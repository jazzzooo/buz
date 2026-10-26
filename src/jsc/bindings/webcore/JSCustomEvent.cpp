#include "config.h"
#include "JSCustomEvent.h"

#include "JSDOMWrapperCache.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/SlotVisitorMacros.h>

namespace Bun {

using namespace JSC;
using namespace WebCore;

template<typename Visitor>
void BunBindgen_WebCoreEvents_CustomEvent::visitAdditionalChildren(Visitor& visitor)
{
    wrapped().detail().visit(visitor);
}

template void BunBindgen_WebCoreEvents_CustomEvent::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCoreEvents_CustomEvent::visitAdditionalChildren(JSC::SlotVisitor&);

namespace Bindgen {
namespace Cpp {

JSCustomEvent* bunBindgenCpp_WebCoreEvents_CustomEvent_construct(
    CppEngineConstructContext<JSCustomEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_CustomEvent_construct_Arguments& args)
{
    auto* zigGlobal = defaultGlobalObject(&ctx.globalObject);
    CustomEvent::Init init;
    if (const auto& dict = args.eventInitDict) {
        init.bubbles = dict->bubbles;
        init.cancelable = dict->cancelable;
        init.composed = dict->composed;
        init.detail = dict->detail;
    }
    auto impl = CustomEvent::create(AtomString { args.type }, init);
    auto* implPtr = impl.ptr();
    auto* wrapper = JSCustomEvent::create(ctx.structure, zigGlobal, WTF::move(impl));
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    ctx.globalObject.vm().writeBarrier(wrapper);
    return wrapper;
}

std::optional<CppAny> bunBindgenCpp_WebCoreEvents_CustomEvent_getter_detail(
    CppEngineCallContext<JSCustomEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_CustomEvent_getter_detail_Arguments&)
{
    return ctx.wrapped().detail().get();
}

void bunBindgenCpp_WebCoreEvents_CustomEvent_method_initCustomEvent(
    CppEngineCallContext<JSCustomEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_CustomEvent_method_initCustomEvent_Arguments& args)
{
    ctx.wrapped().initCustomEvent(ctx.globalObject.vm(), AtomString { args.type }, args.bubbles, args.cancelable, args.detail);
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
