#include "config.h"
#include "SchemaBindings.h"

#include "ReadableStream.h"
#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Cpp {

JSC::JSObject* bunBindgenCpp_WebCoreStreams_ReadableStreamDefaultReader_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_ReadableStreamDefaultReader_construct_Arguments& args)
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
        WebCore::readableStreamDefaultReaderInitializeReadableStreamDefaultReaderCodeGenerator(vm),
        &globalObject);
    JSC::call(
        &globalObject,
        initialize,
        object,
        arguments,
        "ReadableStreamDefaultReader initialization failed"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

} // namespace Bun::Bindgen::Cpp
