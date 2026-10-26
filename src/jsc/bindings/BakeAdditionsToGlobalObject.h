#pragma once
#include "root.h"
#include "BunBuiltinNames.h"
#include "SchemaBindings.h"

namespace Bun {
using namespace JSC;
using namespace WebCore;

// Forward declaration
class JSBakeResponse;
void setupJSBakeResponseClassStructure(JSC::LazyClassStructure::Initializer& init);

struct BakeAdditionsToGlobalObject {
    template<typename Visitor>
    void visit(Visitor& visitor)
    {
        this->m_JSBakeResponseClassStructure.visit(visitor);
        visitor.append(this->m_wrapComponent);
        visitor.append(this->m_asyncLocalStorageInstance);

        this->m_bakeEnsureAsyncLocalStorage.visit(visitor);
        this->m_bakeGetBundleNewRoute.visit(visitor);
        this->m_bakeGetNewRouteParams.visit(visitor);
    }

    void initialize()
    {
        m_JSBakeResponseClassStructure.initLater(
            [](LazyClassStructure::Initializer& init) {
                Bun::setupJSBakeResponseClassStructure(init);
            });

        m_bakeEnsureAsyncLocalStorage.initLater(
            [](const LazyProperty<JSGlobalObject, JSFunction>::Initializer& init) {
                init.set(JSFunction::create(init.vm, init.owner, 1, String("bakeSetAsyncLocalStorage"_s), bun_bindgen_host_BakeInternal_jsFunctionBakeEnsureAsyncLocalStorage, ImplementationVisibility::Public, NoIntrinsic));
            });

        m_bakeGetBundleNewRoute.initLater(
            [](const LazyProperty<JSGlobalObject, JSFunction>::Initializer& init) {
                init.set(JSFunction::create(init.vm, init.owner, 1, String("bundleNewRoute"_s), bun_bindgen_host_BakeInternal_jsFunctionBakeGetBundleNewRouteJSFunction, ImplementationVisibility::Public, NoIntrinsic));
            });

        m_bakeGetNewRouteParams.initLater(
            [](const LazyProperty<JSGlobalObject, JSFunction>::Initializer& init) {
                init.set(JSFunction::create(init.vm, init.owner, 3, String("newRouteParams"_s), bun_bindgen_host_DevServer_newRouteParams, ImplementationVisibility::Public, NoIntrinsic));
            });

    }

    JSValue getBundleNewRouteJSFunction(JSGlobalObject* globalObject)
    {
        return m_bakeGetBundleNewRoute.get(globalObject);
    }

    JSValue getNewRouteParamsJSFunction(JSGlobalObject* globalObject)
    {
        return m_bakeGetNewRouteParams.get(globalObject);
    }

    void ensureAsyncLocalStorageInstance(JSGlobalObject* globalObject, JSObject* asyncLocalStorage)
    {
        m_asyncLocalStorageInstance.set(globalObject->vm(), globalObject, asyncLocalStorage);
    }

    JSValue ensureAsyncLocalStorageInstanceJSFunction(const JSGlobalObject* globalObject)
    {
        return m_bakeEnsureAsyncLocalStorage.get(globalObject);
    }

    JSObject* getAsyncLocalStorage() const
    {
        return m_asyncLocalStorageInstance.get();
    }

    JSC::JSFunction* wrapComponent(JSGlobalObject*);

    template<typename T>
    using LazyPropertyOfGlobalObject = LazyProperty<JSGlobalObject, T>;

    JSC::JSObject* JSBakeResponseConstructor(const JSGlobalObject* global) const { return m_JSBakeResponseClassStructure.constructorInitializedOnMainThread(global); }
    JSC::Structure* JSBakeResponseStructure(const JSGlobalObject* global) const { return m_JSBakeResponseClassStructure.getInitializedOnMainThread(global); }

    JSC::Symbol* reactLegacyElementSymbol(const JSGlobalObject* global) const
    {
        auto& vm = global->vm();
        return JSC::Symbol::create(vm, vm.symbolRegistry().symbolForKey("react.element"_s));
    }

    JSC::Symbol* reactElementSymbol(const JSGlobalObject* global) const
    {
        auto& vm = global->vm();
        return JSC::Symbol::create(vm, vm.symbolRegistry().symbolForKey("react.transitional.element"_s));
    }

    LazyClassStructure m_JSBakeResponseClassStructure;
private:
    WriteBarrier<JSFunction> m_wrapComponent;

    WriteBarrier<JSObject> m_asyncLocalStorageInstance;
    LazyProperty<JSGlobalObject, JSFunction> m_bakeEnsureAsyncLocalStorage;
    LazyProperty<JSGlobalObject, JSFunction> m_bakeGetBundleNewRoute;
    LazyProperty<JSGlobalObject, JSFunction> m_bakeGetNewRouteParams;
};

} // namespace Bun
