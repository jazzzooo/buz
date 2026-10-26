#include "BakeProduction.h"
#include "BunBuiltinNames.h"
#include "JavaScriptCore/CallData.h"
#include "WebCoreJSBuiltins.h"
#include "JavaScriptCore/ArrayConstructor.h"
#include "JavaScriptCore/JSArray.h"
#include "JavaScriptCore/JSPromise.h"
#include "JavaScriptCore/Exception.h"
#include "SchemaBindings.h"
#include <limits>

namespace Bake {

static JSC::JSValue renderRoutesForProdStatic(
    JSC::JSGlobalObject* global,
    const Bun::Bindgen::Engine::BunBindgenEngine_BakeProduction_renderRoutesForProdStatic_Arguments& input)
{
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* allServerFiles = JSC::constructEmptyArray(global, nullptr, input.serverFileCount);
    RETURN_IF_EXCEPTION(scope, {});
    for (const auto& file : input.serverFiles) {
        RELEASE_ASSERT(file.index < input.serverFileCount);
        allServerFiles->putDirectIndex(global, file.index, JSC::jsString(vm, file.specifier));
        RETURN_IF_EXCEPTION(scope, {});
    }

    RELEASE_ASSERT(input.routerTypes.size() <= std::numeric_limits<unsigned>::max());
    const auto routerTypeCount = static_cast<unsigned>(input.routerTypes.size());
    auto* renderStatic = JSC::constructEmptyArray(global, nullptr, routerTypeCount);
    RETURN_IF_EXCEPTION(scope, {});
    auto* getParams = JSC::constructEmptyArray(global, nullptr, routerTypeCount);
    RETURN_IF_EXCEPTION(scope, {});
    auto* clientEntryURLs = JSC::constructEmptyArray(global, nullptr, routerTypeCount);
    RETURN_IF_EXCEPTION(scope, {});
    for (unsigned i = 0; i < routerTypeCount; ++i) {
        const auto& router = input.routerTypes[i];
        renderStatic->putDirectIndex(global, i, router.prerender);
        RETURN_IF_EXCEPTION(scope, {});
        getParams->putDirectIndex(global, i, router.getParams.value_or(JSC::jsNull()));
        RETURN_IF_EXCEPTION(scope, {});
        clientEntryURLs->putDirectIndex(
            global,
            i,
            router.clientEntryURL ? JSC::jsString(vm, *router.clientEntryURL) : JSC::jsNull());
        RETURN_IF_EXCEPTION(scope, {});
    }

    RELEASE_ASSERT(input.routes.size() <= std::numeric_limits<unsigned>::max());
    const auto routeCount = static_cast<unsigned>(input.routes.size());
    auto* patterns = JSC::constructEmptyArray(global, nullptr, routeCount);
    RETURN_IF_EXCEPTION(scope, {});
    auto* files = JSC::constructEmptyArray(global, nullptr, routeCount);
    RETURN_IF_EXCEPTION(scope, {});
    auto* typeAndFlags = JSC::constructEmptyArray(global, nullptr, routeCount);
    RETURN_IF_EXCEPTION(scope, {});
    auto* sourceRouteFiles = JSC::constructEmptyArray(global, nullptr, routeCount);
    RETURN_IF_EXCEPTION(scope, {});
    auto* paramInformation = JSC::constructEmptyArray(global, nullptr, routeCount);
    RETURN_IF_EXCEPTION(scope, {});
    auto* styles = JSC::constructEmptyArray(global, nullptr, routeCount);
    RETURN_IF_EXCEPTION(scope, {});

    for (unsigned i = 0; i < routeCount; ++i) {
        const auto& route = input.routes[i];
        patterns->putDirectIndex(global, i, JSC::jsString(vm, route.pattern));
        RETURN_IF_EXCEPTION(scope, {});

        RELEASE_ASSERT(route.files.size() <= std::numeric_limits<unsigned>::max());
        auto* routeFiles = JSC::constructEmptyArray(global, nullptr, static_cast<unsigned>(route.files.size()));
        RETURN_IF_EXCEPTION(scope, {});
        for (unsigned fileIndex = 0; fileIndex < route.files.size(); ++fileIndex) {
            routeFiles->putDirectIndex(global, fileIndex, JSC::jsNumber(route.files[fileIndex]));
            RETURN_IF_EXCEPTION(scope, {});
        }
        files->putDirectIndex(global, i, routeFiles);
        RETURN_IF_EXCEPTION(scope, {});

        const uint32_t packedTypeAndFlags = route.routerType | (route.noClient ? 1u << 8 : 0);
        typeAndFlags->putDirectIndex(global, i, JSC::jsNumber(packedTypeAndFlags));
        RETURN_IF_EXCEPTION(scope, {});
        sourceRouteFiles->putDirectIndex(global, i, JSC::jsString(vm, route.sourceFile));
        RETURN_IF_EXCEPTION(scope, {});

        if (route.parameters) {
            RELEASE_ASSERT(route.parameters->size() <= std::numeric_limits<unsigned>::max());
            auto* parameters = JSC::constructEmptyArray(global, nullptr, static_cast<unsigned>(route.parameters->size()));
            RETURN_IF_EXCEPTION(scope, {});
            for (unsigned parameterIndex = 0; parameterIndex < route.parameters->size(); ++parameterIndex) {
                parameters->putDirectIndex(global, parameterIndex, JSC::jsString(vm, (*route.parameters)[parameterIndex]));
                RETURN_IF_EXCEPTION(scope, {});
            }
            paramInformation->putDirectIndex(global, i, parameters);
        } else {
            paramInformation->putDirectIndex(global, i, JSC::jsNull());
        }
        RETURN_IF_EXCEPTION(scope, {});

        RELEASE_ASSERT(route.styleIndexes.size() <= std::numeric_limits<unsigned>::max());
        auto* routeStyles = JSC::constructEmptyArray(global, nullptr, static_cast<unsigned>(route.styleIndexes.size()));
        RETURN_IF_EXCEPTION(scope, {});
        for (unsigned styleIndex = 0; styleIndex < route.styleIndexes.size(); ++styleIndex) {
            const auto urlIndex = route.styleIndexes[styleIndex];
            RELEASE_ASSERT(urlIndex < input.styleURLs.size());
            routeStyles->putDirectIndex(global, styleIndex, JSC::jsString(vm, input.styleURLs[urlIndex]));
            RETURN_IF_EXCEPTION(scope, {});
        }
        styles->putDirectIndex(global, i, routeStyles);
        RETURN_IF_EXCEPTION(scope, {});
    }

    JSC::JSFunction* cb = JSC::JSFunction::create(vm, global, WebCore::bakeRenderRoutesForProdStaticCodeGenerator(vm), global);
    JSC::CallData callData = JSC::getCallData(cb);

    JSC::MarkedArgumentBuffer args;
    args.append(JSC::jsString(vm, input.outBase));
    args.append(allServerFiles);
    args.append(renderStatic);
    args.append(getParams);
    args.append(clientEntryURLs);
    args.append(patterns);
    args.append(files);
    args.append(typeAndFlags);
    args.append(sourceRouteFiles);
    args.append(paramInformation);
    args.append(styles);
    if (args.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global, scope);
        RELEASE_AND_RETURN(scope, {});
    }

    NakedPtr<JSC::Exception> returnedException = nullptr;
    auto result = JSC::profiledCall(global, JSC::ProfilingReason::API, cb, callData, JSC::jsUndefined(), args, returnedException);
    if (returnedException) [[unlikely]] {
        // This should be impossible because it returns a promise.
        return JSC::JSPromise::rejectedPromise(global, returnedException->value());
    }
    return uncheckedDowncast<JSC::JSPromise>(result);
}

} // namespace Bake

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_BakeProduction_renderRoutesForProdStatic(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_BakeProduction_renderRoutesForProdStatic_Arguments& args)
{
    return Bake::renderRoutesForProdStatic(&context.globalObject, args);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_BakeAppOptions_createFromModuleDefault(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_BakeAppOptions_createFromModuleDefault_Arguments& args)
{
    auto* global = &context.globalObject;
    auto& vm = JSC::getVM(global);
    auto* function = JSC::JSFunction::create(
        vm,
        global,
        WebCore::bakeAppOptionsCreateFromModuleDefaultCodeGenerator(vm),
        global);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(args.moduleDefault);
    return JSC::call(global, function, JSC::getCallData(function), JSC::jsUndefined(), arguments);
}
