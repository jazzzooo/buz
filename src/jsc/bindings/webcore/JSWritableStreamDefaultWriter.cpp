#include "config.h"
#include "SchemaBindings.h"

#include "JSWritableStream.h"
#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Cpp {

JSC::JSObject* bunBindgenCpp_WebCoreStreams_WritableStreamDefaultWriter_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_WritableStreamDefaultWriter_construct_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::JSValue stream;
    if (args.stream.is_wrapper()) {
        auto* wrapper = WTF::dynamicDowncast<WebCore::JSWritableStream>(args.stream.wrapper());
        RELEASE_ASSERT(wrapper);
        stream = wrapper->wrapped().internalWritableStream();
    } else {
        stream = args.stream.internal();
    }
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(stream);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return nullptr;
    }

    auto* object = context.createObject();
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* initialize = JSC::JSFunction::create(
        vm,
        &globalObject,
        WebCore::writableStreamDefaultWriterInitializeWritableStreamDefaultWriterCodeGenerator(vm),
        &globalObject);
    JSC::call(
        &globalObject,
        initialize,
        object,
        arguments,
        "WritableStreamDefaultWriter initialization failed"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

} // namespace Bun::Bindgen::Cpp
