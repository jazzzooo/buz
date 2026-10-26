#include "config.h"
#include "Bindgen/Optional.h"
#include "SchemaBindings.h"

#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSCInlines.h>


namespace Bun::Bindgen::Cpp {

JSC::JSObject* bunBindgenCpp_WebCoreStreams_TransformStream_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_WebCoreStreams_TransformStream_construct_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    const auto* transformer = nestedOptionalValue(args.transformer);
    const bool internal = transformer && transformer->internal_transformer.has_value();
    std::optional<JSC::JSValue> start;
    std::optional<JSC::JSValue> transform;
    std::optional<JSC::JSValue> flush;
    if (transformer && !internal) {
        const auto* convertedStart = transformer->start.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        RELEASE_ASSERT(convertedStart);
        start = *convertedStart;
        const auto* convertedTransform = transformer->transform.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        RELEASE_ASSERT(convertedTransform);
        transform = *convertedTransform;
        const auto* convertedFlush = transformer->flush.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        RELEASE_ASSERT(convertedFlush);
        flush = *convertedFlush;

        const auto* readableType = transformer->readableType.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        RELEASE_ASSERT(readableType);
        if (readableType->has_value()) {
            JSC::throwRangeError(&globalObject, scope, "TransformStream transformer has a readableType"_s);
            return nullptr;
        }
        const auto* writableType = transformer->writableType.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        RELEASE_ASSERT(writableType);
        if (writableType->has_value()) {
            JSC::throwRangeError(&globalObject, scope, "TransformStream transformer has a writableType"_s);
            return nullptr;
        }
    }

    const auto* writableStrategy = nestedOptionalValue(args.writableStrategy);
    const auto* readableStrategy = nestedOptionalValue(args.readableStrategy);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(JSC::jsBoolean(internal));
    if (transformer)
        transformer->source_identity.appendTo(arguments);
    else
        arguments.append(JSC::jsNull());
    arguments.append(start.value_or(JSC::jsUndefined()));
    arguments.append(transform.value_or(JSC::jsUndefined()));
    arguments.append(flush.value_or(JSC::jsUndefined()));
    arguments.append(JSC::jsNumber(writableStrategy && writableStrategy->highWaterMark ? *writableStrategy->highWaterMark : 1));
    arguments.append(writableStrategy && writableStrategy->size ? *writableStrategy->size : JSC::jsUndefined());
    arguments.append(JSC::jsNumber(readableStrategy && readableStrategy->highWaterMark ? *readableStrategy->highWaterMark : 0));
    arguments.append(readableStrategy && readableStrategy->size ? *readableStrategy->size : JSC::jsUndefined());
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return nullptr;
    }

    auto* object = context.createObject();
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* executable = WebCore::transformStreamInitializeTransformStreamCodeGenerator(vm);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* initialize = JSC::JSFunction::create(
        vm,
        &globalObject,
        executable,
        &globalObject);
    RETURN_IF_EXCEPTION(scope, nullptr);
    JSC::call(
        &globalObject,
        initialize,
        object,
        arguments,
        "TransformStream initialization failed"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

} // namespace Bun::Bindgen::Cpp
