#include "config.h"
#include "SchemaBindings.h"

#include "JSDOMExceptionHandling.h"
#include "JSMessagePort.h"
#include "MessagePortPipe.h"
#include "ScriptExecutionContext.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Cpp {

using namespace JSC;
using namespace WebCore;

JSObject* bunBindgenCpp_WebCoreEvents_MessageChannel_construct(
    CppPlainConstructContext& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageChannel_construct_Arguments&)
{
    auto* global = &ctx.globalObject;
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* zigGlobal = defaultGlobalObject(global);
    auto* context = zigGlobal->scriptExecutionContext();
    if (!context) [[unlikely]] {
        throwConstructorScriptExecutionContextUnavailableError(*global, scope, "MessageChannel"_s);
        return nullptr;
    }

    auto pipe = MessagePortPipe::tryCreate();
    if (!pipe) {
        throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    auto first = MessagePort::tryCreate(*context, Ref { *pipe }, 0);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (first.hasException()) {
        propagateException(*global, scope, first.releaseException());
        return nullptr;
    }
    auto second = MessagePort::tryCreate(*context, pipe.releaseNonNull(), 1);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (second.hasException()) {
        propagateException(*global, scope, second.releaseException());
        return nullptr;
    }
    JSValue port1 = toJSNewlyCreated(global, zigGlobal, first.releaseReturnValue());
    RETURN_IF_EXCEPTION(scope, nullptr);
    JSValue port2 = toJSNewlyCreated(global, zigGlobal, second.releaseReturnValue());
    RETURN_IF_EXCEPTION(scope, nullptr);

    auto* object = ctx.createObject();
    RETURN_IF_EXCEPTION(scope, nullptr);
    object->putDirectOffset(vm, BunBindgen_WebCoreEvents_MessageChannel_offset_port1, port1);
    object->putDirectOffset(vm, BunBindgen_WebCoreEvents_MessageChannel_offset_port2, port2);
    return object;
}

JSValue bunBindgenCpp_WebCoreEvents_MessageChannel_getter_port1(
    CppCallContext& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageChannel_getter_port1_Arguments& args)
{
    return toJS(&ctx.globalObject, defaultGlobalObject(&ctx.globalObject), args.bindingThis.port1);
}

JSValue bunBindgenCpp_WebCoreEvents_MessageChannel_getter_port2(
    CppCallContext& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageChannel_getter_port2_Arguments& args)
{
    return toJS(&ctx.globalObject, defaultGlobalObject(&ctx.globalObject), args.bindingThis.port2);
}

} // namespace Bun::Bindgen::Cpp
