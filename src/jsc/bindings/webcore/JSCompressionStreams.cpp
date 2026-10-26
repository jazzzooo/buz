#include "config.h"
#include "SchemaBindings.h"

#include "Bindgen/EnumerationConversion.h"
#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Cpp {

static JSC::JSObject* constructCompressionStream(
    CppPlainConstructContext& context,
    CompressionFormat format,
    JSC::FunctionExecutable* executable)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    RETURN_IF_EXCEPTION(scope, nullptr);

    auto formatString = enumerationString(format);
    if (!formatString) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return nullptr;
    }
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(JSC::jsString(vm, WTF::move(*formatString)));
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return nullptr;
    }

    auto* object = context.createObject();
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* initialize = JSC::JSFunction::create(vm, &globalObject, executable, &globalObject);
    JSC::call(&globalObject, initialize, object, arguments, "Compression stream initialization failed"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

JSC::JSObject* bunBindgenCpp_WebCoreStreams_CompressionStream_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_CompressionStream_construct_Arguments& args)
{
    return constructCompressionStream(context, args.format,
        WebCore::compressionStreamInitializeCompressionStreamCodeGenerator(context.globalObject.vm()));
}

JSC::JSObject* bunBindgenCpp_WebCoreStreams_DecompressionStream_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_DecompressionStream_construct_Arguments& args)
{
    return constructCompressionStream(context, args.format,
        WebCore::decompressionStreamInitializeDecompressionStreamCodeGenerator(context.globalObject.vm()));
}

} // namespace Bun::Bindgen::Cpp
