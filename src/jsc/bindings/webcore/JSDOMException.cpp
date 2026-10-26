#include "config.h"
#include "JSDOMException.h"

#include "JSDOMWrapperCache.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>

namespace WebCore {

using namespace JSC;

bool JSDOMExceptionOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, AbstractSlotVisitor& visitor, ASCIILiteral* reason)
{
    UNUSED_PARAM(handle);
    UNUSED_PARAM(visitor);
    UNUSED_PARAM(reason);
    return false;
}

void JSDOMExceptionOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSDOMException*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

JSDOMException* bunBindgenCpp_WebCoreDOMException_DOMException_construct(
    CppEngineConstructContext<JSDOMException>& ctx,
    const BunBindgenCpp_WebCoreDOMException_DOMException_construct_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto& vm = JSC::getVM(global);
    auto* zigGlobal = defaultGlobalObject(global);

    String name = "Error"_s;
    std::optional<CppAny> cause;
    if (args.second) {
        if (args.second->is_options()) {
            const auto& options = args.second->options();
            if (options.name)
                name = *options.name;
            cause = options.cause;
        } else {
            RELEASE_ASSERT(args.second->is_name());
            name = args.second->name();
        }
    }

    auto impl = DOMException::create(String { args.message }, WTF::move(name));
    auto* implPtr = impl.ptr();
    auto* wrapper = JSDOMException::create(ctx.structure, zigGlobal, WTF::move(impl));
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    if (cause)
        cause->defineOwnDataProperty(vm, *wrapper, vm.propertyNames->cause, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    return wrapper;
}

uint16_t bunBindgenCpp_WebCoreDOMException_DOMException_getter_code(
    CppEngineCallContext<JSDOMException>& ctx,
    const BunBindgenCpp_WebCoreDOMException_DOMException_getter_code_Arguments&)
{
    return ctx.wrapped().legacyCode();
}

WTF::String bunBindgenCpp_WebCoreDOMException_DOMException_getter_name(
    CppEngineCallContext<JSDOMException>& ctx,
    const BunBindgenCpp_WebCoreDOMException_DOMException_getter_name_Arguments&)
{
    return ctx.wrapped().name();
}

WTF::String bunBindgenCpp_WebCoreDOMException_DOMException_getter_message(
    CppEngineCallContext<JSDOMException>& ctx,
    const BunBindgenCpp_WebCoreDOMException_DOMException_getter_message_Arguments&)
{
    return ctx.wrapped().message();
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
