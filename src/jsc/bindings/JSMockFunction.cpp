#include "root.h"

#include "BindingAssertions.h"
#include "SchemaBindingsErrorCodes.h"
#include "JavaScriptCore/Error.h"
#include "JSMockFunction.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSPromise.h>
#include "ZigGlobalObject.h"
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/Completion.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include "DOMClientIsoSubspaces.h"
#include "DOMIsoSubspaces.h"
#include "BunClientData.h"
#include <JavaScriptCore/LazyProperty.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSPromiseConstructor.h>
#include <JavaScriptCore/LazyPropertyInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include <JavaScriptCore/Weak.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/WeakMapImpl.h>
#include <JavaScriptCore/WeakMapImplInlines.h>
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/JSModuleEnvironment.h>
#include <JavaScriptCore/JSModuleNamespaceObject.h>
#include <wtf/Scope.h>
#include "AsyncContextFrame.h"
#include "ErrorCode.h"
#include <bit>

namespace Bun {

/**
 * intended to be used in an if statement as an abstraction over this double if statement
 *
 * if(jsValue) {
 *   if(auto value = jsDynamicCast(jsValue)) {
 *     ...
 *   }
 * }
 *
 * the reason this is needed is because jsDynamicCast will segfault if given a zero JSValue
 */
template<typename To>
inline To tryJSDynamicCast(JSValue from)
{
    if (!from) [[unlikely]]
        return nullptr;
    if (!from.isCell()) [[unlikely]]
        return nullptr;
    return dynamicDowncast<std::remove_pointer_t<To>>(from.asCell());
}

/**
 * intended to be used in an if statement as an abstraction over this double if statement
 *
 * if(jsValue) {
 *   if(auto value = jsDynamicCast(jsValue)) {
 *     ...
 *   }
 * }
 *
 * the reason this is needed is because jsDynamicCast will segfault if given a zero JSValue
 */
template<typename To, typename WriteBarrierT>
inline To tryJSDynamicCast(JSC::WriteBarrier<WriteBarrierT>& from)
{
    if (!from) [[unlikely]]
        return nullptr;

    return dynamicDowncast<std::remove_pointer_t<To>>(from.get());
}

uint64_t JSMockModule::s_nextInvocationId = 0;

// This is taken from JSWeakSet
// We only want to hold onto the list of active spies which haven't already been collected
// So we use a WeakSet
// Unlike using WeakSet from JS, we are able to iterate through the WeakSet.
class ActiveSpySet final : public WeakMapImpl<WeakMapBucket<WeakMapBucketDataKey>> {
public:
    using Base = WeakMapImpl<WeakMapBucket<WeakMapBucketDataKey>>;

    DECLARE_EXPORT_INFO;

    static Structure* createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
    {
        return Structure::create(vm, globalObject, prototype, TypeInfo(JSWeakSetType, StructureFlags), info());
    }

    static ActiveSpySet* create(VM& vm, Structure* structure)
    {
        ActiveSpySet* instance = new (NotNull, allocateCell<ActiveSpySet>(vm)) ActiveSpySet(vm, structure);
        instance->finishCreation(vm);
        return instance;
    }

private:
    ActiveSpySet(VM& vm, Structure* structure)
        : Base(vm, structure)
    {
    }
};

static_assert(std::is_final<ActiveSpySet>::value, "Required for JSType based casting");
const ClassInfo ActiveSpySet::s_info = { "ActiveSpySet"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(ActiveSpySet) };

static void storeMockValue(JSC::VM& vm, JSC::JSCell& owner, JSC::WriteBarrier<JSC::Unknown>& slot, JSC::JSValue value)
{
    slot.set(vm, &owner, value);
}

static void storeMockValue(JSC::VM& vm, JSC::JSCell& owner, JSC::WriteBarrier<JSC::Unknown>& slot, Bun::Bindgen::CppAny value)
{
    value.storeIn(vm, owner, slot);
}

class JSMockImplementation final : public JSNonFinalObject {
public:
    enum class Kind : uint8_t {
        Call,
        ReturnValue,
        ReturnThis,
        RejectedValue,
    };

    template<typename Value>
    static JSMockImplementation* create(JSC::JSGlobalObject* globalObject, JSC::Structure* structure, Kind kind, Value heldValue, bool isOnce)
    {
        auto& vm = JSC::getVM(globalObject);
        JSMockImplementation* impl = new (NotNull, allocateCell<JSMockImplementation>(vm)) JSMockImplementation(vm, structure, kind, isOnce);
        impl->finishCreation(vm);
        storeMockValue(vm, *impl, impl->underlyingValue, heldValue);
        return impl;
    }

    using Base = JSC::JSNonFinalObject;
    static Structure* createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
    {
        return Structure::create(vm, globalObject, prototype, TypeInfo(JSC::ObjectType, StructureFlags), info());
    }
    template<typename, JSC::SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<JSMockImplementation, UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForJSMockImplementation.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForJSMockImplementation = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForJSMockImplementation.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForJSMockImplementation = std::forward<decltype(space)>(space); });
    }

    // either a function or a return value, depends on kind
    mutable JSC::WriteBarrier<JSC::Unknown> underlyingValue;

    // a combination of a pointer to the next implementation and a flag indicating if this is a once implementation
    // - undefined            - no next value
    // - jsNumber(1)          - no next value + is a once implementation
    // - JSMockImplementation - next value + is a once implementation
    mutable JSC::WriteBarrier<JSC::Unknown> nextValueOrSentinel;

    DECLARE_EXPORT_INFO;
    DECLARE_VISIT_CHILDREN;

    Kind kind { Kind::ReturnValue };

    bool isOnce()
    {
        return !nextValueOrSentinel.get().isUndefined();
    }

    JSMockImplementation(JSC::VM& vm, JSC::Structure* structure, Kind kind, bool isOnce)
        : Base(vm, structure)
        , underlyingValue(jsUndefined(), JSC::WriteBarrierEarlyInit)
        , nextValueOrSentinel(isOnce ? jsNumber(1) : jsUndefined(), JSC::WriteBarrierEarlyInit)
        , kind(kind)
    {
    }

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm);
    }
};

template<typename Visitor>
void JSMockImplementation::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSMockImplementation* fn = uncheckedDowncast<JSMockImplementation>(cell);
    ASSERT_GC_OBJECT_INHERITS(fn, info());
    Base::visitChildren(fn, visitor);

    visitor.append(fn->underlyingValue);
    visitor.append(fn->nextValueOrSentinel);
}

DEFINE_VISIT_CHILDREN(JSMockImplementation);

enum class CallbackKind : uint8_t {
    Call,
    GetterSetter,
};

const ClassInfo JSMockImplementation::s_info = { "MockImpl"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSMockImplementation) };

class JSMockFunction : public JSC::InternalFunction {
public:
    using Base = JSC::InternalFunction;
    static constexpr unsigned StructureFlags = Base::StructureFlags;

    static JSMockFunction* create(JSC::VM& vm, Zig::GlobalObject* globalObject, JSC::Structure* structure, CallbackKind kind = CallbackKind::Call)
    {
        JSMockFunction* function = new (NotNull, JSC::allocateCell<JSMockFunction>(vm)) JSMockFunction(vm, structure, kind);
        function->finishCreation(vm);

        // Do not forget to set the original name: https://github.com/oven-sh/bun/issues/8794
        function->m_originalName.set(vm, function, globalObject->commonStrings().mockedFunctionString(globalObject));

        return function;
    }
    static Structure* createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
    {
        return Structure::create(vm, globalObject, prototype, TypeInfo(InternalFunctionType, StructureFlags), info());
    }

    DECLARE_INFO;

    DECLARE_VISIT_CHILDREN;
    template<typename Visitor> void visitAdditionalChildrenInGCThread(Visitor&);
    DECLARE_VISIT_OUTPUT_CONSTRAINTS;

    JSC::LazyProperty<JSMockFunction, JSObject> mock;
    // three pointers to implementation objects
    // head of the list, this one is run next
    mutable JSC::WriteBarrier<JSC::Unknown> implementation;
    // this contains the non-once implementation. there is only ever one of these
    mutable JSC::WriteBarrier<JSC::Unknown> fallbackImplmentation;
    // the last once implementation
    mutable JSC::WriteBarrier<JSC::Unknown> tail;
    // original implementation from spy. separate from `implementation` so restoration always works
    mutable JSC::WriteBarrier<JSC::Unknown> spyOriginal;
    mutable JSC::WriteBarrier<JSC::JSArray> calls;
    mutable JSC::WriteBarrier<JSC::JSArray> contexts;
    mutable JSC::WriteBarrier<JSC::JSArray> invocationCallOrder;
    mutable JSC::WriteBarrier<JSC::JSArray> instances;
    mutable JSC::WriteBarrier<JSC::JSArray> returnValues;

    JSC::Weak<JSObject> spyTarget;
    JSC::Identifier spyIdentifier;
    unsigned spyAttributes = 0;

    static constexpr unsigned SpyAttributeESModuleNamespace = 1 << 30;

    JSString* jsName()
    {
        return m_originalName.get();
    }

    void setName(const WTF::String& name)
    {
        auto& vm = this->vm();
        auto* nameStr = jsString(vm, name);

        // Do not forget to set the original name: https://github.com/oven-sh/bun/issues/8794
        m_originalName.set(vm, this, nameStr);

        this->putDirect(vm, vm.propertyNames->name, nameStr, JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly);
    }

    void copyNameAndLength(JSC::VM& vm, JSGlobalObject* global, JSC::JSValue value)
    {
        auto catcher = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        WTF::String nameToUse;
        if (auto* fn = dynamicDowncast<JSFunction>(value)) {
            nameToUse = fn->name(vm);
            JSValue lengthJSValue = fn->get(global, vm.propertyNames->length);
            if (lengthJSValue.isNumber()) {
                this->putDirect(vm, vm.propertyNames->length, (lengthJSValue), JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly);
            }
        } else if (auto* fn = dynamicDowncast<JSMockFunction>(value)) {
            JSValue nameValue = fn->get(global, vm.propertyNames->name);
            if (!catcher.exception()) {
                nameToUse = nameValue.toWTFString(global);
            }
        } else if (auto* fn = dynamicDowncast<InternalFunction>(value)) {
            nameToUse = fn->name();
        } else {
            nameToUse = "mockConstructor"_s;
        }
        this->setName(nameToUse);

        if (catcher.exception()) {
            (void)catcher.tryClearException();
        }
    }

    void initMock()
    {
        mock.initLater(
            [](const JSC::LazyProperty<JSMockFunction, JSObject>::Initializer& init) {
                JSMockFunction* mock = init.owner;
                Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(mock->globalObject());
                auto& vm = JSC::getVM(globalObject);
                auto scope = DECLARE_THROW_SCOPE(vm);
                JSC::Structure* structure = globalObject->mockModule.mockObjectStructure.getInitializedOnMainThread(globalObject);
                JSObject* object = JSC::constructEmptyObject(init.vm, structure);
                object->putDirectOffset(init.vm, 0, mock->getCalls());
                RETURN_IF_EXCEPTION(scope, );
                object->putDirectOffset(init.vm, 1, mock->getContexts());
                RETURN_IF_EXCEPTION(scope, );
                object->putDirectOffset(init.vm, 2, mock->getInstances());
                RETURN_IF_EXCEPTION(scope, );
                object->putDirectOffset(init.vm, 3, mock->getReturnValues());
                RETURN_IF_EXCEPTION(scope, );
                object->putDirectOffset(init.vm, 4, mock->getInvocationCallOrder());
                RETURN_IF_EXCEPTION(scope, );
                init.set(object);
            });
    }

    void clear()
    {
        this->calls.clear();
        this->instances.clear();
        this->returnValues.clear();
        this->contexts.clear();
        this->invocationCallOrder.clear();

        if (this->mock.isInitialized()) {
            this->initMock();
        }
    }

    void reset()
    {
        this->clear();
        this->implementation.clear();
        this->fallbackImplmentation.clear();
        this->tail.clear();
    }

    void clearSpy()
    {
        this->reset();

        if (auto* target = this->spyTarget.get()) {
            JSValue implValue = this->spyOriginal.get();
            if (!implValue) {
                implValue = jsUndefined();
            }

            // Reset the spy back to the original value.
            if (this->spyAttributes & SpyAttributeESModuleNamespace) {
                if (auto* moduleNamespaceObject = tryJSDynamicCast<JSModuleNamespaceObject*>(target)) {
                    moduleNamespaceObject->overrideExportValue(moduleNamespaceObject->globalObject(), this->spyIdentifier, implValue);
                }
            } else if (auto index = parseIndex(this->spyIdentifier)) {
                // Use putDirectIndex for numeric property keys (e.g., spyOn(arr, 0))
                target->putDirectIndex(globalObject(), *index, implValue, this->spyAttributes, PutDirectIndexLikePutDirect);
            } else {
                target->putDirect(this->vm(), this->spyIdentifier, implValue, this->spyAttributes);
            }
        }

        this->spyTarget.clear();
        this->spyIdentifier = JSC::Identifier();
        this->spyAttributes = 0;
    }

    JSArray* getCalls() const
    {
        JSArray* val = calls.get();
        if (!val) {
            val = JSC::constructEmptyArray(globalObject(), nullptr, 0);
            if (!val) Bun::assertPendingException(globalObject());
            if (!val) return {};
            this->calls.set(vm(), this, val);
        }
        return val;
    }
    JSArray* getContexts() const
    {
        JSArray* val = contexts.get();
        if (!val) {
            val = JSC::constructEmptyArray(globalObject(), nullptr, 0);
            if (!val) Bun::assertPendingException(globalObject());
            if (!val) return {};
            this->contexts.set(vm(), this, val);
        }
        return val;
    }
    JSArray* getInstances() const
    {
        JSArray* val = instances.get();
        if (!val) {
            val = JSC::constructEmptyArray(globalObject(), nullptr, 0);
            if (!val) Bun::assertPendingException(globalObject());
            if (!val) return {};
            this->instances.set(vm(), this, val);
        }
        return val;
    }
    JSArray* getReturnValues() const
    {
        JSArray* val = returnValues.get();
        if (!val) {
            val = JSC::constructEmptyArray(globalObject(), nullptr, 0);
            if (!val) Bun::assertPendingException(globalObject());
            if (!val) return {};
            this->returnValues.set(vm(), this, val);
        }
        return val;
    }
    JSArray* getInvocationCallOrder() const
    {
        JSArray* val = invocationCallOrder.get();
        if (!val) {
            val = JSC::constructEmptyArray(globalObject(), nullptr, 0);
            if (!val) Bun::assertPendingException(globalObject());
            if (!val) return {};
            this->invocationCallOrder.set(vm(), this, val);
        }
        return val;
    }

    template<typename, JSC::SubspaceAccess mode>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<JSMockFunction, UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForJSMockFunction.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForJSMockFunction = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForJSMockFunction.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForJSMockFunction = std::forward<decltype(space)>(space); });
    }

    JSMockFunction(JSC::VM& vm, JSC::Structure* structure, CallbackKind wrapKind)
        : Base(vm, structure, bun_bindgen_host_JSMockHost_jsMockFunctionCall, bun_bindgen_host_JSMockHost_jsMockFunctionCall)
    {
        initMock();
    }
};

template<typename Visitor>
void JSMockFunction::visitAdditionalChildrenInGCThread(Visitor& visitor)
{
    JSMockFunction* fn = this;
    ASSERT_GC_OBJECT_INHERITS(fn, info());

    visitor.append(fn->implementation);
    visitor.append(fn->tail);
    visitor.append(fn->fallbackImplmentation);
    visitor.append(fn->calls);
    visitor.append(fn->contexts);
    visitor.append(fn->instances);
    visitor.append(fn->returnValues);
    visitor.append(fn->invocationCallOrder);
    visitor.append(fn->spyOriginal);
    fn->mock.visit(visitor);
}

template<typename Visitor>
void JSMockFunction::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSMockFunction* fn = uncheckedDowncast<JSMockFunction>(cell);
    ASSERT_GC_OBJECT_INHERITS(fn, info());
    Base::visitChildren(fn, visitor);
    fn->visitAdditionalChildrenInGCThread<Visitor>(visitor);
}

template<typename Visitor>
void JSMockFunction::visitOutputConstraintsImpl(JSCell* cell, Visitor& visitor)
{
    JSMockFunction* thisObject = uncheckedDowncast<JSMockFunction>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    thisObject->visitAdditionalChildrenInGCThread<Visitor>(visitor);
}

DEFINE_VISIT_CHILDREN(JSMockFunction);
DEFINE_VISIT_ADDITIONAL_CHILDREN_IN_GC_THREAD(JSMockFunction);
DEFINE_VISIT_OUTPUT_CONSTRAINTS(JSMockFunction);

JSMockFunction* jsMockFunctionCast(JSC::JSValue value)
{
    return tryJSDynamicCast<JSMockFunction*>(value);
}

bool isJSMockFunction(JSC::JSValue value) noexcept
{
    return !!jsMockFunctionCast(value);
}

static JSMockFunction* validatedMockFunction(JSC::JSValue value)
{
    auto* function = jsMockFunctionCast(value);
    RELEASE_ASSERT(function);
    return function;
}

template<typename Value>
static void pushImpl(JSMockFunction* fn, JSGlobalObject* jsGlobalObject, JSMockImplementation::Kind kind, Value value)
{
    Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(jsGlobalObject);
    auto& vm = JSC::getVM(globalObject);

    if (auto* current = tryJSDynamicCast<JSMockImplementation*, Unknown>(fn->fallbackImplmentation)) {
        storeMockValue(vm, *current, current->underlyingValue, value);
        current->kind = kind;
        return;
    }

    JSMockImplementation* impl = JSMockImplementation::create(globalObject, globalObject->mockModule.mockImplementationStructure.getInitializedOnMainThread(globalObject), kind, value, false);
    fn->fallbackImplmentation.set(vm, fn, impl);
    if (auto* tail = tryJSDynamicCast<JSMockImplementation*, Unknown>(fn->tail)) {
        tail->nextValueOrSentinel.set(vm, tail, impl);
    } else {
        fn->implementation.set(vm, fn, impl);
    }
}

template<typename Value>
static void pushImplOnce(JSMockFunction* fn, JSGlobalObject* jsGlobalObject, JSMockImplementation::Kind kind, Value value)
{
    Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(jsGlobalObject);
    auto& vm = JSC::getVM(globalObject);

    JSMockImplementation* impl = JSMockImplementation::create(globalObject, globalObject->mockModule.mockImplementationStructure.getInitializedOnMainThread(globalObject), kind, value, true);

    if (!fn->implementation) {
        fn->implementation.set(vm, fn, impl);
    }
    if (auto* tail = tryJSDynamicCast<JSMockImplementation*, Unknown>(fn->tail)) {
        tail->nextValueOrSentinel.set(vm, tail, impl);
    } else {
        fn->implementation.set(vm, fn, impl);
    }
    if (auto fallback = fn->fallbackImplmentation.get()) {
        impl->nextValueOrSentinel.set(vm, impl, fallback);
    }
    fn->tail.set(vm, fn, impl);
}

class JSMockFunctionPrototype final : public JSC::JSNonFinalObject {
public:
    using Base = JSC::JSNonFinalObject;

    static JSMockFunctionPrototype* create(JSC::VM& vm, JSGlobalObject* globalObject, JSC::Structure* structure)
    {
        JSMockFunctionPrototype* ptr = new (NotNull, JSC::allocateCell<JSMockFunctionPrototype>(vm)) JSMockFunctionPrototype(vm, globalObject, structure);
        ptr->finishCreation(vm, globalObject);
        return ptr;
    }

    DECLARE_INFO;
    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSMockFunctionPrototype, Base);
        return &vm.plainObjectSpace();
    }
    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

private:
    JSMockFunctionPrototype(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM&, JSC::JSGlobalObject*);
};

#define BUN_BINDGEN_OBJECT_SURFACE_JSMockFunctionPrototype
#define BUN_BINDGEN_OBJECT_SURFACE_JSMockMetadataPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSMockMetadataPrototype
#undef BUN_BINDGEN_OBJECT_SURFACE_JSMockFunctionPrototype

const ClassInfo JSMockFunction::s_info = { "Mock"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSMockFunction) };

class SpyWeakHandleOwner final : public JSC::WeakHandleOwner {
public:
    void finalize(JSC::Handle<JSC::Unknown>, void* context) final {}
};

static SpyWeakHandleOwner& weakValueHandleOwner()
{
    static NeverDestroyed<SpyWeakHandleOwner> jscWeakValueHandleOwner;
    return jscWeakValueHandleOwner;
}

const ClassInfo JSMockFunctionPrototype::s_info = { "Mock"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSMockFunctionPrototype) };

static void resetSpies(Zig::GlobalObject* globalObject)
{
    if (!globalObject->mockModule.activeSpies) {
        return;
    }
    auto spiesValue = globalObject->mockModule.activeSpies.get();

    ActiveSpySet* activeSpies = uncheckedDowncast<ActiveSpySet>(spiesValue);
    MarkedArgumentBuffer active;
    activeSpies->takeSnapshot(active);
    size_t size = active.size();

    for (size_t i = 0; i < size; ++i) {
        JSValue spy = active.at(i);
        if (!spy.isObject())
            continue;

        auto* spyObject = uncheckedDowncast<JSMockFunction>(spy);
        spyObject->clearSpy();
    }
    globalObject->mockModule.activeSpies.clear();
}

static void clearAllMocks(Zig::GlobalObject* globalObject)
{
    if (!globalObject->mockModule.activeMocks) {
        return;
    }
    auto spiesValue = globalObject->mockModule.activeMocks.get();

    ActiveSpySet* activeSpies = uncheckedDowncast<ActiveSpySet>(spiesValue);
    MarkedArgumentBuffer active;
    activeSpies->takeSnapshot(active);
    size_t size = active.size();

    for (size_t i = 0; i < size; ++i) {
        JSValue spy = active.at(i);
        if (!spy.isObject())
            continue;

        auto* spyObject = uncheckedDowncast<JSMockFunction>(spy);
        // Clearing mocks preserves spy installation and only clears recorded state.
        spyObject->clear();
    }
}

JSMockModule JSMockModule::create(JSC::JSGlobalObject* globalObject)
{
    JSMockModule mock;
    mock.mockFunctionStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::Structure>::Initializer& init) {
            auto& vm = init.vm;
            auto* prototype = JSMockFunctionPrototype::create(vm, init.owner, JSMockFunctionPrototype::createStructure(vm, init.owner, init.owner->functionPrototype()));
            auto* structure = JSMockFunction::createStructure(vm, init.owner, prototype);
            init.set(structure);
        });
    mock.mockResultStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::Structure>::Initializer& init) {
            Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(init.owner);
            JSC::Structure* structure = globalObject->structureCache().emptyObjectStructureForPrototype(
                globalObject,
                globalObject->objectPrototype(),
                2);
            JSC::PropertyOffset offset;

            structure = structure->addPropertyTransition(
                init.vm,
                structure,
                JSC::Identifier::fromString(init.vm, "type"_s),
                0,
                offset);

            structure = structure->addPropertyTransition(
                init.vm,
                structure,
                JSC::Identifier::fromString(init.vm, "value"_s),

                0,
                offset);

            init.set(structure);
        });
    mock.activeSpySetStructure.initLater([](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::Structure>::Initializer& init) {
        Structure* implementation = ActiveSpySet::createStructure(init.vm, init.owner, jsNull());
        init.set(implementation);
    });

    mock.mockImplementationStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::Structure>::Initializer& init) {
            Structure* implementation = JSMockImplementation::createStructure(init.vm, init.owner, jsNull());
            init.set(implementation);
        });
    mock.mockObjectStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::Structure>::Initializer& init) {
            Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(init.owner);

            auto* prototype = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype());
            bunBindgenObjectSurface_JSMockMetadataPrototype_install(init.vm, prototype->classInfo(), *prototype);

            JSC::Structure* structure
                = globalObject->structureCache().emptyObjectStructureForPrototype(
                    globalObject,
                    prototype,
                    5);
            JSC::PropertyOffset offset;
            structure = structure->addPropertyTransition(
                init.vm,
                structure,
                JSC::Identifier::fromString(init.vm, "calls"_s),
                JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly,
                offset);
            structure = structure->addPropertyTransition(
                init.vm,
                structure,
                JSC::Identifier::fromString(init.vm, "contexts"_s),
                JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly,
                offset);
            structure = structure->addPropertyTransition(
                init.vm,
                structure,
                JSC::Identifier::fromString(init.vm, "instances"_s),
                JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly,
                offset);
            structure = structure->addPropertyTransition(
                init.vm,
                structure,
                JSC::Identifier::fromString(init.vm, "results"_s),
                JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly,
                offset);
            structure = structure->addPropertyTransition(
                init.vm,
                structure,
                JSC::Identifier::fromString(init.vm, "invocationCallOrder"_s),
                JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly,
                offset);

            init.set(structure);
        });
    mock.withImplementationCleanupFunction.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSFunction>::Initializer& init) {
            init.set(JSC::JSFunction::create(init.vm, init.owner, 2, String(), bun_bindgen_host_JSMockHost_jsMockFunctionWithImplementationCleanup, ImplementationVisibility::Public));
        });
    mock.mockWithImplementationCleanupDataStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
            init.set(Bun::MockWithImplementationCleanupData::createStructure(init.vm, init.owner, init.owner->objectPrototype()));
        });
    return mock;
}

template<typename Visitor> void JSMockModule::visit(Visitor& visitor)
{
#define VISIT_JSMOCKMODULE_GC_MEMBER(T, name) \
    name.visit(visitor);
    FOR_EACH_JSMOCKMODULE_GC_MEMBER(VISIT_JSMOCKMODULE_GC_MEMBER)
#undef VISIT_JSMOCKMODULE_GC_MEMBER
}

template void JSMockModule::visit(JSC::AbstractSlotVisitor&);
template void JSMockModule::visit(JSC::SlotVisitor&);

static JSValue createMockResult(JSC::VM& vm, Zig::GlobalObject* globalObject, const WTF::String& type, JSC::JSValue value)
{
    JSC::Structure* structure = globalObject->mockModule.mockResultStructure.getInitializedOnMainThread(globalObject);

    JSC::JSObject* result = JSC::constructEmptyObject(vm, structure);
    result->putDirectOffset(vm, 0, jsString(vm, type));
    result->putDirectOffset(vm, 1, value);
    return result;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_JSMockHost_invoke(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSMockHost_invoke_Arguments& input)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto* fn = validatedMockFunction(input.mock);
    JSC::JSValue thisValue = input.receiver;
    const auto arguments = input.arguments;
    Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSC::ArgList args(
        std::bit_cast<JSC::EncodedJSValue*>(const_cast<JSC::JSValue*>(arguments.data())),
        static_cast<unsigned>(arguments.size()));
    JSC::JSArray* argumentsArray = nullptr;
    {
        JSC::ObjectInitializationScope object(vm);
        argumentsArray = JSC::JSArray::tryCreateUninitializedRestricted(
            object,
            globalObject->arrayStructureForIndexingTypeDuringAllocation(JSC::ArrayWithContiguous),
            arguments.size());
        for (size_t i = 0; i < arguments.size(); i++) {
            argumentsArray->initializeIndex(object, i, arguments[i]);
        }
    }

    JSC::JSArray* calls = fn->calls.get();
    if (calls) {
        calls->push(globalObject, argumentsArray);
        RETURN_IF_EXCEPTION(scope, {});
    } else {
        JSC::ObjectInitializationScope object(vm);
        calls = JSC::JSArray::tryCreateUninitializedRestricted(
            object,
            globalObject->arrayStructureForIndexingTypeDuringAllocation(JSC::ArrayWithContiguous),
            1);
        calls->initializeIndex(object, 0, argumentsArray);
        fn->calls.set(vm, fn, calls);
    }

    JSC::JSArray* contexts = fn->contexts.get();
    if (contexts) {
        contexts->push(globalObject, thisValue);
        RETURN_IF_EXCEPTION(scope, {});
    } else {
        JSC::ObjectInitializationScope object(vm);
        contexts = JSC::JSArray::tryCreateUninitializedRestricted(
            object,
            globalObject->arrayStructureForIndexingTypeDuringAllocation(JSC::ArrayWithContiguous),
            1);
        contexts->initializeIndex(object, 0, thisValue);
        fn->contexts.set(vm, fn, contexts);
    }

    auto invocationId = JSMockModule::nextInvocationId();
    JSC::JSArray* invocationCallOrder = fn->invocationCallOrder.get();
    if (invocationCallOrder) {
        invocationCallOrder->push(globalObject, jsNumber(invocationId));
        RETURN_IF_EXCEPTION(scope, {});
    } else {
        JSC::ObjectInitializationScope object(vm);
        invocationCallOrder = JSC::JSArray::tryCreateUninitializedRestricted(
            object,
            globalObject->arrayStructureForIndexingTypeDuringAllocation(JSC::ArrayWithContiguous),
            1);
        invocationCallOrder->initializeIndex(object, 0, jsNumber(invocationId));
        fn->invocationCallOrder.set(vm, fn, invocationCallOrder);
    }

    unsigned int returnValueIndex = 0;
    auto setReturnValue = [&](JSC::JSValue value) -> void {
        if (auto* returnValuesArray = fn->returnValues.get()) {
            returnValuesArray->push(globalObject, value);
            RETURN_IF_EXCEPTION(scope, );
            returnValueIndex = returnValuesArray->length() - 1;
        } else {
            JSC::ObjectInitializationScope object(vm);
            returnValuesArray = JSC::JSArray::tryCreateUninitializedRestricted(
                object,
                globalObject->arrayStructureForIndexingTypeDuringAllocation(JSC::ArrayWithContiguous),
                1);
            returnValuesArray->initializeIndex(object, 0, value);
            fn->returnValues.set(vm, fn, returnValuesArray);
        }
    };

    if (auto* impl = tryJSDynamicCast<JSMockImplementation*, Unknown>(fn->implementation)) {
        if (impl->isOnce()) {
            auto next = impl->nextValueOrSentinel.get();
            fn->implementation.set(vm, fn, next);
            if (next.isNumber() || !dynamicDowncast<JSMockImplementation>(next)->isOnce()) {
                fn->tail.clear();
            }
        }

        switch (impl->kind) {
        case JSMockImplementation::Kind::Call: {
            JSValue result = impl->underlyingValue.get();
            JSC::CallData callData = JSC::getCallData(result);
            if (callData.type == JSC::CallData::Type::None) [[unlikely]] {
                throwTypeError(globalObject, scope, "Expected mock implementation to be callable"_s);
                return {};
            }

            setReturnValue(createMockResult(vm, globalObject, "incomplete"_s, jsUndefined()));

            auto topExceptionScope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

            JSValue returnValue = Bun::call(globalObject, result, callData, thisValue, args);

            if (auto* exc = topExceptionScope.exception()) {
                if (auto* returnValuesArray = fn->returnValues.get()) {
                    returnValuesArray->putDirectIndex(globalObject, returnValueIndex, createMockResult(vm, globalObject, "throw"_s, exc->value()));
                    fn->returnValues.set(vm, fn, returnValuesArray);
                    (void)topExceptionScope.tryClearException();
                    JSC::throwException(globalObject, scope, exc);
                    return {};
                }
            }

            if (!returnValue) [[unlikely]] {
                returnValue = jsUndefined();
            }

            if (auto* returnValuesArray = fn->returnValues.get()) {
                returnValuesArray->putDirectIndex(globalObject, returnValueIndex, createMockResult(vm, globalObject, "return"_s, returnValue));
                fn->returnValues.set(vm, fn, returnValuesArray);
            }

            return returnValue;
        }
        case JSMockImplementation::Kind::ReturnValue: {
            JSValue returnValue = impl->underlyingValue.get();
            setReturnValue(createMockResult(vm, globalObject, "return"_s, returnValue));
            return returnValue;
        }
        case JSMockImplementation::Kind::ReturnThis: {
            setReturnValue(createMockResult(vm, globalObject, "return"_s, thisValue));
            return thisValue;
        }
        case JSMockImplementation::Kind::RejectedValue: {
            JSValue rejectedPromise = JSC::JSPromise::rejectedPromise(globalObject, impl->underlyingValue.get());
            RETURN_IF_EXCEPTION(scope, {});
            setReturnValue(createMockResult(vm, globalObject, "return"_s, rejectedPromise));
            return rejectedPromise;
        }
        default: {
            RELEASE_ASSERT_NOT_REACHED();
        }
        }
    }

    setReturnValue(createMockResult(vm, globalObject, "return"_s, jsUndefined()));
    return jsUndefined();
}

void JSMockFunctionPrototype::finishCreation(JSC::VM& vm, JSC::JSGlobalObject*)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSMockFunctionPrototype_install(vm, JSMockFunction::info(), *this);
}

std::optional<JSC::JSValue> Bindgen::Engine::bunBindgenEngine_Expect_mockFunctionCalls(
    Bindgen::EngineCallContext&,
    const Bindgen::Engine::BunBindgenEngine_Expect_mockFunctionCalls_Arguments& args)
{
    if (auto* mock = tryJSDynamicCast<JSMockFunction*>(args.value))
        return mock->getCalls();
    return std::nullopt;
}

std::optional<JSC::JSValue> Bindgen::Engine::bunBindgenEngine_Expect_mockFunctionReturns(
    Bindgen::EngineCallContext&,
    const Bindgen::Engine::BunBindgenEngine_Expect_mockFunctionReturns_Arguments& args)
{
    if (auto* mock = tryJSDynamicCast<JSMockFunction*>(args.value))
        return mock->getReturnValues();
    return std::nullopt;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_JSMockHost_lastCall(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSMockHost_lastCall_Arguments& input)
{
    auto* globalObject = &context.globalObject;
    const auto& thisValue = input.object;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    if (!thisValue)
        return jsUndefined();
    auto* thisObject = JSC::asObject(*thisValue);
    JSValue callsValue = thisObject->get(globalObject, Identifier::fromString(vm, "calls"_s));
    RETURN_IF_EXCEPTION(throwScope, {});

    if (auto callsArray = dynamicDowncast<JSC::JSArray>(callsValue)) {
        auto len = callsArray->length();
        if (len > 0) {
            return callsArray->getIndex(globalObject, len - 1);
        }
    }
    return jsUndefined();
}

const JSC::ClassInfo MockWithImplementationCleanupData::s_info = { "MockWithImplementationCleanupData"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(MockWithImplementationCleanupData) };

template<typename, JSC::SubspaceAccess mode>
JSC::GCClient::IsoSubspace* MockWithImplementationCleanupData::subspaceFor(JSC::VM& vm)
{
    return WebCore::subspaceForImpl<MockWithImplementationCleanupData, WebCore::UseCustomHeapCellType::No>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForMockWithImplementationCleanupData.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForMockWithImplementationCleanupData = std::forward<decltype(space)>(space); },
        [](auto& spaces) { return spaces.m_subspaceForMockWithImplementationCleanupData.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForMockWithImplementationCleanupData = std::forward<decltype(space)>(space); });
}

MockWithImplementationCleanupData* MockWithImplementationCleanupData::create(VM& vm, Structure* structure)
{
    MockWithImplementationCleanupData* mod = new (NotNull, allocateCell<MockWithImplementationCleanupData>(vm)) MockWithImplementationCleanupData(vm, structure);
    return mod;
}
Structure* MockWithImplementationCleanupData::createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
{
    return Structure::create(vm, globalObject, prototype, TypeInfo(ObjectType, StructureFlags), info());
}

MockWithImplementationCleanupData::MockWithImplementationCleanupData(VM& vm, Structure* structure)
    : Base(vm, structure)
{
}

void MockWithImplementationCleanupData::finishCreation(VM& vm, JSMockFunction* fn, JSValue impl, JSValue tail, JSValue fallback)
{
    Base::finishCreation(vm);
    this->internalField(0).set(vm, this, fn);
    this->internalField(1).set(vm, this, impl);
    this->internalField(2).set(vm, this, tail);
    this->internalField(3).set(vm, this, fallback);
}

template<typename Visitor>
void MockWithImplementationCleanupData::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* thisObject = uncheckedDowncast<MockWithImplementationCleanupData>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
}

DEFINE_VISIT_CHILDREN(MockWithImplementationCleanupData);

MockWithImplementationCleanupData* MockWithImplementationCleanupData::create(JSC::JSGlobalObject* globalObject, JSMockFunction* fn, JSValue impl, JSValue tail, JSValue fallback)
{
    auto* obj = create(globalObject->vm(), static_cast<Zig::GlobalObject*>(globalObject)->mockModule.mockWithImplementationCleanupDataStructure.getInitializedOnMainThread(globalObject));
    obj->finishCreation(globalObject->vm(), fn, impl, tail, fallback);
    return obj;
}

void Bindgen::Engine::bunBindgenEngine_JSMockHost_finishImplementation(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSMockHost_finishImplementation_Arguments& args)
{
    if (!args.cleanup)
        return;
    auto* cleanup = uncheckedDowncast<MockWithImplementationCleanupData>(args.cleanup->asCell());
    auto* function = validatedMockFunction(cleanup->internalField(0).get());
    auto& vm = context.globalObject.vm();
    function->implementation.set(vm, function, cleanup->internalField(1).get());
    function->tail.set(vm, function, cleanup->internalField(2).get());
    function->fallbackImplmentation.set(vm, function, cleanup->internalField(3).get());
}
std::optional<JSC::JSValue> Bindgen::Engine::bunBindgenEngine_JSMockHost_withImplementation(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSMockHost_withImplementation_Arguments& input)
{
    auto* jsGlobalObject = &context.globalObject;
    auto* thisObject = validatedMockFunction(input.mock);
    auto implementation = input.implementation;
    JSC::JSValue callback = input.callback;
    Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(jsGlobalObject);

    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::CallData callData = JSC::getCallData(callback);
    ASSERT(callData.type != JSC::CallData::Type::None);

    auto lastImpl = thisObject->implementation.get();
    auto lastTail = thisObject->tail.get();
    auto lastFallback = thisObject->fallbackImplmentation.get();

    JSMockImplementation* impl = JSMockImplementation::create(
        globalObject,
        globalObject->mockModule.mockImplementationStructure.getInitializedOnMainThread(globalObject),
        JSMockImplementation::Kind::Call,
        implementation,
        false);

    thisObject->implementation.set(vm, thisObject, impl);
    thisObject->fallbackImplmentation.clear();
    thisObject->tail.clear();

    auto restoreImplementation = WTF::makeScopeExit([&] {
        thisObject->implementation.set(vm, thisObject, lastImpl);
        thisObject->tail.set(vm, thisObject, lastTail);
        thisObject->fallbackImplmentation.set(vm, thisObject, lastFallback);
    });

    JSValue returnValue = JSC::call(globalObject, callback, callData, jsUndefined(), ArgList());
    RETURN_IF_EXCEPTION(scope, {});

    if (auto promise = tryJSDynamicCast<JSC::JSPromise*>(returnValue)) {
        auto capability = JSC::JSPromise::createNewPromiseCapability(globalObject, globalObject->promiseConstructor());
        auto ctx = MockWithImplementationCleanupData::create(globalObject, thisObject, lastImpl, lastTail, lastFallback);

        JSFunction* cleanup = globalObject->mockModule.withImplementationCleanupFunction.getInitializedOnMainThread(globalObject);
        JSFunction* performPromiseThenFunction = globalObject->performPromiseThenFunction();
        auto callData = JSC::getCallData(performPromiseThenFunction);
        MarkedArgumentBuffer arguments;
        arguments.append(promise);
        arguments.append(cleanup);
        arguments.append(cleanup);
        arguments.append(capability);
        arguments.append(ctx);
        ASSERT(!arguments.hasOverflowed());
        call(globalObject, performPromiseThenFunction, callData, jsUndefined(), arguments);
        RETURN_IF_EXCEPTION(scope, {});

        restoreImplementation.release();
        RELEASE_AND_RETURN(scope, JSC::JSValue(promise));
    }

    RELEASE_AND_RETURN(scope, std::nullopt);
}
} // namespace Bun

using namespace Bun;
using namespace JSC;

JSC::JSValue Bindgen::Engine::bunBindgenEngine_JSMockHost_spyOn(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSMockHost_spyOn_Arguments& input)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto* target = JSC::asObject(input.target);
    JSC::JSValue propertyKeyValue = input.property;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);

    PropertyName propertyKey = propertyKeyValue.toPropertyKey(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    if (propertyKey.isNull()) {
        throwVMError(globalObject, scope, "spyOn(target, prop) expects a property key"_s);
        return {};
    }

    JSC::JSObject* object = target;
    if (object->type() == JSC::JSType::GlobalProxyType)
        object = uncheckedDowncast<JSC::JSGlobalProxy>(object)->target();

    JSC::PropertySlot slot(object, JSC::PropertySlot::InternalMethodType::HasProperty);
    bool hasValue = object->getPropertySlot(globalObject, propertyKey, slot);
    RETURN_IF_EXCEPTION(scope, {});

    // easymode: regular property or missing property
    if (!hasValue || slot.isValue()) {
        JSValue value = jsUndefined();
        if (hasValue) {
            if (slot.isTaintedByOpaqueObject()) [[unlikely]] {
                // if it's a Proxy or JSModuleNamespaceObject
                value = object->get(globalObject, propertyKey);
            } else {
                value = slot.getValue(globalObject, propertyKey);
            }

            if (dynamicDowncast<JSMockFunction>(value)) {
                return value;
            }
        }

        auto* mock = JSMockFunction::create(vm, globalObject, globalObject->mockModule.mockFunctionStructure.getInitializedOnMainThread(globalObject), CallbackKind::GetterSetter);
        mock->spyTarget = JSC::Weak<JSObject>(object, &weakValueHandleOwner(), nullptr);
        mock->spyIdentifier = propertyKey.isSymbol() ? Identifier::fromUid(vm, propertyKey.uid()) : Identifier::fromString(vm, propertyKey.publicName());
        mock->spyAttributes = hasValue ? slot.attributes() : 0;
        unsigned attributes = 0;

        if (hasValue && ((slot.attributes() & PropertyAttribute::Function) != 0 || (value.isCell() && value.isCallable()))) {
            if (hasValue)
                attributes = slot.attributes();

            mock->copyNameAndLength(vm, globalObject, value);

            if (JSModuleNamespaceObject* moduleNamespaceObject = tryJSDynamicCast<JSModuleNamespaceObject*>(object)) {
                moduleNamespaceObject->overrideExportValue(globalObject, propertyKey, mock);
                mock->spyAttributes |= JSMockFunction::SpyAttributeESModuleNamespace;
            } else if (auto index = parseIndex(propertyKey)) {
                // Use putDirectIndex for numeric property keys (e.g., spyOn(arr, 0))
                object->putDirectIndex(globalObject, *index, mock, attributes, PutDirectIndexLikePutDirect);
            } else {
                object->putDirect(vm, propertyKey, mock, attributes);
            }

            RETURN_IF_EXCEPTION(scope, {});

            pushImpl(mock, globalObject, JSMockImplementation::Kind::Call, value);
        } else {
            if (hasValue)
                attributes = slot.attributes();

            attributes |= PropertyAttribute::Accessor;

            if (JSModuleNamespaceObject* moduleNamespaceObject = tryJSDynamicCast<JSModuleNamespaceObject*>(object)) {
                moduleNamespaceObject->overrideExportValue(globalObject, propertyKey, mock);
                mock->spyAttributes |= JSMockFunction::SpyAttributeESModuleNamespace;
            } else if (auto index = parseIndex(propertyKey)) {
                // For indexed properties, set the mock directly instead of wrapping in GetterSetter
                object->putDirectIndex(globalObject, *index, mock, attributes, PutDirectIndexLikePutDirect);
            } else {
                object->putDirectAccessor(globalObject, propertyKey, JSC::GetterSetter::create(vm, globalObject, mock, mock), attributes);
            }

            // mock->setName(propertyKey.publicName());
            RETURN_IF_EXCEPTION(scope, {});

            pushImpl(mock, globalObject, JSMockImplementation::Kind::ReturnValue, value);
        }

        mock->spyOriginal.set(vm, mock, value);

        {
            if (!globalObject->mockModule.activeSpies) {
                ActiveSpySet* activeSpies = ActiveSpySet::create(vm, globalObject->mockModule.activeSpySetStructure.getInitializedOnMainThread(globalObject));
                globalObject->mockModule.activeSpies.set(vm, activeSpies);
            }
            ActiveSpySet* activeSpies = uncheckedDowncast<ActiveSpySet>(globalObject->mockModule.activeSpies.get());
            activeSpies->add(vm, mock, mock);
        }

        {
            if (!globalObject->mockModule.activeMocks) {
                ActiveSpySet* activeMocks = ActiveSpySet::create(vm, globalObject->mockModule.activeSpySetStructure.getInitializedOnMainThread(globalObject));
                globalObject->mockModule.activeMocks.set(vm, activeMocks);
            }
            ActiveSpySet* activeMocks = uncheckedDowncast<ActiveSpySet>(globalObject->mockModule.activeMocks.get());
            activeMocks->add(vm, mock, mock);
        }

        return mock;
    }

    // hardmode: accessor property
    throwVMError(globalObject, scope, "spyOn(target, prop) does not support accessor properties yet"_s);
    return {};
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_JSMockHost_create(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_JSMockHost_create_Arguments& input)
{
    auto* lexicalGlobalObject = &context.globalObject;
    const auto& implementation = input.implementation;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSMockFunction* thisObject = JSMockFunction::create(
        vm,
        globalObject,
        globalObject->mockModule.mockFunctionStructure.getInitializedOnMainThread(globalObject));

    if (!thisObject) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    if (implementation) {
        if (implementation->is_callable()) {
            JSValue value = implementation->callable();
            thisObject->copyNameAndLength(vm, lexicalGlobalObject, value);
            RETURN_IF_EXCEPTION(scope, {});
            pushImpl(thisObject, globalObject, JSMockImplementation::Kind::Call, value);
        } else {
            auto value = implementation->value();
            // jest doesn't support doing `jest.fn(10)`, but we support it.
            pushImpl(thisObject, globalObject, JSMockImplementation::Kind::ReturnValue, value);
            thisObject->setName("mockConstructor"_s);
        }
    } else {
        thisObject->setName("mockConstructor"_s);
    }

    if (!globalObject->mockModule.activeMocks) {
        ActiveSpySet* activeMocks = ActiveSpySet::create(vm, globalObject->mockModule.activeSpySetStructure.getInitializedOnMainThread(globalObject));
        globalObject->mockModule.activeMocks.set(vm, activeMocks);
    }

    ActiveSpySet* activeMocks = uncheckedDowncast<ActiveSpySet>(globalObject->mockModule.activeMocks.get());
    activeMocks->add(vm, thisObject, thisObject);

    return thisObject;
}

namespace Bun::Bindgen::Engine {

void bunBindgenEngine_JSMockHost_clearHistory(EngineCallContext&, const BunBindgenEngine_JSMockHost_clearHistory_Arguments& args)
{
    validatedMockFunction(args.mock)->clear();
}

void bunBindgenEngine_JSMockHost_reset(EngineCallContext&, const BunBindgenEngine_JSMockHost_reset_Arguments& args)
{
    validatedMockFunction(args.mock)->reset();
}

void bunBindgenEngine_JSMockHost_restore(EngineCallContext&, const BunBindgenEngine_JSMockHost_restore_Arguments& args)
{
    validatedMockFunction(args.mock)->clearSpy();
}

JSC::JSValue bunBindgenEngine_JSMockHost_implementation(EngineCallContext&, const BunBindgenEngine_JSMockHost_implementation_Arguments& args)
{
    auto* mock = validatedMockFunction(args.mock);
    if (auto* implementation = tryJSDynamicCast<JSMockImplementation*, Unknown>(mock->implementation)) {
        if (implementation->kind == JSMockImplementation::Kind::Call)
            return implementation->underlyingValue.get();
    }
    return jsUndefined();
}

JSC::JSValue bunBindgenEngine_JSMockHost_name(EngineCallContext& context, const BunBindgenEngine_JSMockHost_name_Arguments& args)
{
    auto* name = validatedMockFunction(args.mock)->jsName();
    return name ? name : jsEmptyString(context.globalObject.vm());
}

JSC::JSValue bunBindgenEngine_JSMockHost_history(EngineCallContext&, const BunBindgenEngine_JSMockHost_history_Arguments& args)
{
    auto* mock = validatedMockFunction(args.mock);
    return mock->mock.getInitializedOnMainThread(mock);
}

void bunBindgenEngine_JSMockHost_setName(EngineCallContext&, const BunBindgenEngine_JSMockHost_setName_Arguments& args)
{
    validatedMockFunction(args.mock)->setName(args.name);
}

void bunBindgenEngine_JSMockHost_installImplementation(EngineCallContext& context, const BunBindgenEngine_JSMockHost_installImplementation_Arguments& args)
{
    auto* mock = validatedMockFunction(args.mock);
    JSMockImplementation::Kind kind;
    switch (args.kind) {
    case decltype(args.kind)::call:
        kind = JSMockImplementation::Kind::Call;
        break;
    case decltype(args.kind)::return_value:
        kind = JSMockImplementation::Kind::ReturnValue;
        break;
    case decltype(args.kind)::return_this:
        kind = JSMockImplementation::Kind::ReturnThis;
        break;
    case decltype(args.kind)::rejected:
        kind = JSMockImplementation::Kind::RejectedValue;
        break;
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
    if (args.value) {
        if (args.once)
            pushImplOnce(mock, &context.globalObject, kind, *args.value);
        else
            pushImpl(mock, &context.globalObject, kind, *args.value);
    } else if (args.once) {
        pushImplOnce(mock, &context.globalObject, kind, jsUndefined());
    } else {
        pushImpl(mock, &context.globalObject, kind, jsUndefined());
    }
}

void bunBindgenEngine_JSMockHost_installResolvedValue(EngineCallContext& context, const BunBindgenEngine_JSMockHost_installResolvedValue_Arguments& args)
{
    auto* mock = validatedMockFunction(args.mock);
    auto* promise = JSC::JSPromise::resolvedPromise(&context.globalObject, args.value);
    if (args.once)
        pushImplOnce(mock, &context.globalObject, JSMockImplementation::Kind::ReturnValue, promise);
    else
        pushImpl(mock, &context.globalObject, JSMockImplementation::Kind::ReturnValue, promise);
}

void bunBindgenEngine_JSMockHost_restoreAll(EngineCallContext& context, const BunBindgenEngine_JSMockHost_restoreAll_Arguments&)
{
    resetSpies(uncheckedDowncast<Zig::GlobalObject>(&context.globalObject));
}

void bunBindgenEngine_JSMockHost_clearAll(EngineCallContext& context, const BunBindgenEngine_JSMockHost_clearAll_Arguments&)
{
    clearAllMocks(uncheckedDowncast<Zig::GlobalObject>(&context.globalObject));
}

}
