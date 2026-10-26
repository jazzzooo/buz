#include "config.h"
#include "JSCloseEvent.h"

#include "JSDOMWrapperCache.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

JSCloseEvent* bunBindgenCpp_WebCoreEvents_CloseEvent_construct(
    CppEngineConstructContext<JSCloseEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_CloseEvent_construct_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(ctx.globalObject.vm());
    auto* zigGlobal = defaultGlobalObject(&ctx.globalObject);
    CloseEvent::Init init;
    if (const auto& dict = args.eventInitDict) {
        init.bubbles = dict->bubbles;
        init.cancelable = dict->cancelable;
        init.composed = dict->composed;
        init.code = dict->code;
        init.reason = dict->reason;
        init.wasClean = dict->was_clean;
    } else {
        init.reason = emptyString();
    }
    auto impl = CloseEvent::tryCreate(AtomString { args.type }, init);
    if (!impl) {
        throwOutOfMemoryError(&ctx.globalObject, scope);
        return nullptr;
    }
    auto* implPtr = impl.get();
    auto* wrapper = JSCloseEvent::create(ctx.structure, zigGlobal, impl.releaseNonNull());
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    return wrapper;
}

bool bunBindgenCpp_WebCoreEvents_CloseEvent_getter_wasClean(
    CppEngineCallContext<JSCloseEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_CloseEvent_getter_wasClean_Arguments&)
{
    return ctx.wrapped().wasClean();
}

uint16_t bunBindgenCpp_WebCoreEvents_CloseEvent_getter_code(
    CppEngineCallContext<JSCloseEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_CloseEvent_getter_code_Arguments&)
{
    return ctx.wrapped().code();
}

WTF::String bunBindgenCpp_WebCoreEvents_CloseEvent_getter_reason(
    CppEngineCallContext<JSCloseEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_CloseEvent_getter_reason_Arguments&)
{
    return ctx.wrapped().reason();
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
