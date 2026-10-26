#include "config.h"
#include "JSWritableStream.h"

#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/StrongInlines.h>

namespace WebCore {

using namespace JSC;

bool JSWritableStreamOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void*, AbstractSlotVisitor&, ASCIILiteral*)
{
    return false;
}

void JSWritableStreamOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSWritableStream*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {

using namespace JSC;
using namespace WebCore;

template<typename Visitor>
void BunBindgen_WebCoreStreams_WritableStream::visitAdditionalChildren(Visitor& visitor)
{
    // InternalWritableStream opts out of the global guarded root set.
    wrapped().internalWritableStream().visitAggregate(visitor);
}

template void BunBindgen_WebCoreStreams_WritableStream::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCoreStreams_WritableStream::visitAdditionalChildren(JSC::SlotVisitor&);

namespace Bindgen::Cpp {

JSWritableStream* bunBindgenCpp_WebCoreStreams_WritableStream_construct(
    CppEngineConstructContext<JSWritableStream>& ctx,
    const BunBindgenCpp_WebCoreStreams_WritableStream_construct_Arguments& args)
{
    auto& vm = ctx.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* global = defaultGlobalObject(&ctx.globalObject);
    const auto* sink = args.sink ? args.sink->convert() : nullptr;
    RETURN_IF_EXCEPTION(scope, nullptr);
    const auto* strategy = args.strategy && *args.strategy ? &**args.strategy : nullptr;
    MarkedArgumentBuffer arguments;
    arguments.append(args.underlyingSink.value_or(jsUndefined()));
    arguments.append(jsBoolean(sink && sink->type.has_value()));
    arguments.append(sink ? sink->start.value_or(jsUndefined()) : jsUndefined());
    arguments.append(sink ? sink->write.value_or(jsUndefined()) : jsUndefined());
    arguments.append(sink ? sink->close.value_or(jsUndefined()) : jsUndefined());
    arguments.append(sink ? sink->abort.value_or(jsUndefined()) : jsUndefined());
    arguments.append(jsNumber(strategy ? strategy->highWaterMark.value_or(1) : 1));
    arguments.append(strategy ? strategy->size.value_or(jsUndefined()) : jsUndefined());
    auto result = InternalWritableStream::createFromUnderlyingSink(*global, arguments);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (result.hasException()) [[unlikely]] {
        propagateException(ctx.globalObject, scope, result.releaseException());
        return nullptr;
    }

    Strong<JSObject> protectedInternal(vm, result.releaseReturnValue());
    auto stream = WritableStream::create(InternalWritableStream::fromObject(*global, *protectedInternal.get()));
    auto* native = stream.ptr();
    auto* wrapper = JSWritableStream::create(ctx.structure, global, WTF::move(stream));
    cacheWrapper(global->world(), native, wrapper);
    return wrapper;
}

bool bunBindgenCpp_WebCoreStreams_WritableStream_getter_locked(
    CppEngineCallContext<JSWritableStream>& ctx,
    const BunBindgenCpp_WebCoreStreams_WritableStream_getter_locked_Arguments&)
{
    return ctx.wrapped().locked();
}

JSValue bunBindgenCpp_WebCoreStreams_WritableStream_method_abort(
    CppEngineCallContext<JSWritableStream>& ctx,
    const BunBindgenCpp_WebCoreStreams_WritableStream_method_abort_Arguments& args)
{
    return ctx.wrapped().internalWritableStream().abort(ctx.globalObject, args.reason ? &*args.reason : nullptr);
}

JSValue bunBindgenCpp_WebCoreStreams_WritableStream_method_close(
    CppEngineCallContext<JSWritableStream>& ctx,
    const BunBindgenCpp_WebCoreStreams_WritableStream_method_close_Arguments&)
{
    return ctx.wrapped().internalWritableStream().close(ctx.globalObject);
}

JSValue bunBindgenCpp_WebCoreStreams_WritableStream_method_getWriter(
    CppEngineCallContext<JSWritableStream>& ctx,
    const BunBindgenCpp_WebCoreStreams_WritableStream_method_getWriter_Arguments&)
{
    return ctx.wrapped().internalWritableStream().getWriter(ctx.globalObject);
}

} // namespace Bindgen::Cpp
} // namespace Bun
