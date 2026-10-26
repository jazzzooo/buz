#include "config.h"
#include "SchemaBindings.h"

#include "ReadableStream.h"
#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Cpp {

JSC::JSObject* bunBindgenCpp_WebCoreStreams_ReadableStreamBYOBReader_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStreamBYOBReader_construct_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(args.stream);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return nullptr;
    }

    auto* object = context.createObject();
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* initialize = JSC::JSFunction::create(
        vm,
        &globalObject,
        WebCore::readableStreamBYOBReaderInitializeReadableStreamBYOBReaderCodeGenerator(vm),
        &globalObject);
    JSC::call(
        &globalObject,
        initialize,
        object,
        arguments,
        "ReadableStreamBYOBReader initialization failed"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

JSC::JSValue bunBindgenCpp_WebCoreStreams_ReadableStreamBYOBReader_method_read(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStreamBYOBReader_method_read_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(args.view);
    arguments.append(JSC::jsNumber(args.options && args.options->has_value() ? args.options->value().min : uint64_t { 1 }));
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return {};
    }

    auto* function = JSC::JSFunction::create(
        vm,
        &globalObject,
        WebCore::readableStreamBYOBReaderReadCodeGenerator(vm),
        &globalObject);
    auto result = JSC::call(
        &globalObject,
        function,
        args.bindingThis,
        arguments,
        "ReadableStreamBYOBReader.read failed"_s);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

} // namespace Bun::Bindgen::Cpp
