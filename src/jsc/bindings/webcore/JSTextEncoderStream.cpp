#include "config.h"
#include "SchemaBindings.h"

#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Cpp {

JSC::JSObject* bunBindgenCpp_WebCoreStreams_TextEncoderStream_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_TextEncoderStream_construct_Arguments&)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* object = context.createObject();
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* initialize = JSC::JSFunction::create(
        vm,
        &globalObject,
        WebCore::textEncoderStreamInitializeTextEncoderStreamCodeGenerator(vm),
        &globalObject);
    JSC::call(
        &globalObject,
        initialize,
        object,
        JSC::ArgList(),
        "TextEncoderStream initialization failed"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

} // namespace Bun::Bindgen::Cpp
