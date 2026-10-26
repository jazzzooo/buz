#include "config.h"
#include "SchemaBindings.h"

#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Cpp {

ReadableStreamBYOBRequestStateResult bunBindgenCpp_WebCoreStreams_createReadableStreamBYOBRequest(
    CppCallContext&,
    const BunBindgenCpp_WebCoreStreams_createReadableStreamBYOBRequest_Arguments& args)
{
    return { args.controller, args.view };
}

void bunBindgenCpp_WebCoreStreams_ReadableStreamBYOBRequest_method_respond(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStreamBYOBRequest_method_respond_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(JSC::jsNumber(args.bytesWritten));
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return;
    }

    auto* function = JSC::JSFunction::create(
        vm,
        &globalObject,
        WebCore::readableStreamBYOBRequestRespondCodeGenerator(vm),
        &globalObject);
    JSC::call(
        &globalObject,
        function,
        args.bindingThis,
        arguments,
        "ReadableStreamBYOBRequest.respond failed"_s);
    RETURN_IF_EXCEPTION(scope, void());
}

void bunBindgenCpp_WebCoreStreams_ReadableStreamBYOBRequest_method_respondWithNewView(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStreamBYOBRequest_method_respondWithNewView_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(args.view);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return;
    }

    auto* function = JSC::JSFunction::create(
        vm,
        &globalObject,
        WebCore::readableStreamBYOBRequestRespondWithNewViewCodeGenerator(vm),
        &globalObject);
    JSC::call(
        &globalObject,
        function,
        args.bindingThis,
        arguments,
        "ReadableStreamBYOBRequest.respondWithNewView failed"_s);
    RETURN_IF_EXCEPTION(scope, void());
}

} // namespace Bun::Bindgen::Cpp
