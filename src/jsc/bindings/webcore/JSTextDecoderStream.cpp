#include "config.h"
#include "SchemaBindings.h"

#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Cpp {

JSC::JSObject* bunBindgenCpp_WebCoreStreams_TextDecoderStream_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_TextDecoderStream_construct_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    bool fatal = false;
    bool ignoreBOM = false;
    if (args.options) {
        fatal = args.options->fatal;
        ignoreBOM = args.options->ignore_bom;
    }

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(JSC::jsString(vm, args.label));
    arguments.append(JSC::jsBoolean(fatal));
    arguments.append(JSC::jsBoolean(ignoreBOM));
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return nullptr;
    }

    auto* object = context.createObject();
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* initialize = JSC::JSFunction::create(
        vm,
        &globalObject,
        WebCore::textDecoderStreamInitializeTextDecoderStreamCodeGenerator(vm),
        &globalObject);
    JSC::call(
        &globalObject,
        initialize,
        object,
        arguments,
        "TextDecoderStream initialization failed"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

} // namespace Bun::Bindgen::Cpp
