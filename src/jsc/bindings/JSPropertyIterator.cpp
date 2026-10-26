#include "root.h"

#include "BunClientData.h"
#include "ZigGlobalObject.h"
#include "JavaScriptCore/JSType.h"
#include "JavaScriptCore/EnumerationMode.h"
#include "JavaScriptCore/Error.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "JavaScriptCore/ThrowScope.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSGlobalObject.h"
#include "JavaScriptCore/PropertyNameArray.h"
#include "wtf/Assertions.h"
#include "wtf/FastMalloc.h"
#include "SchemaBindings.h"

namespace Bun {
using namespace JSC;

class JSPropertyIterator {
public:
    JSPropertyIterator(JSC::VM& vm, RefPtr<JSC::PropertyNameArray>&& properties)
        : properties(WTF::move(properties))
        , vm(vm)
    {
    }

    RefPtr<JSC::PropertyNameArray> properties;
    Ref<JSC::VM> vm;
    bool isSpecialProxy = false;
    static JSPropertyIterator* create(JSC::VM& vm, RefPtr<JSC::PropertyNameArray> data)
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(JSPropertyIterator)).getValue(storage))
            return nullptr;
        return new (NotNull, storage) JSPropertyIterator(vm, WTF::move(data));
    }

    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(JSPropertyIterator);
};

Bindgen::Engine::BunBindgenEngine_property_iterators_propertyIteratorCreate_Return Bindgen::Engine::bunBindgenEngine_property_iterators_propertyIteratorCreate(
    EngineCallContext& context,
    const BunBindgenEngine_property_iterators_propertyIteratorCreate_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto* object = JSC::asObject(args.value);

    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::PropertyNameArrayBuilder array(vm, PropertyNameMode::StringsAndSymbols, PrivateSymbolMode::Exclude);

    if (object->hasNonReifiedStaticProperties()) [[unlikely]] {
        object->reifyAllStaticProperties(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
    }

#if OS(WINDOWS)
    if (object->type() == JSC::ProxyObjectType) [[unlikely]] {
        // Check if we're actually iterating through the JSEnvironmentVariableMap's proxy.
        auto* zigGlobal = defaultGlobalObject(globalObject);
        if (zigGlobal->m_processEnvObject.isInitialized()) {
            if (object == zigGlobal->m_processEnvObject.get(zigGlobal)) {
                object->methodTable()->getOwnPropertyNames(
                    object,
                    globalObject,
                    array,
                    DontEnumPropertiesMode::Exclude);
                RETURN_IF_EXCEPTION(scope, {});

                if (array.size() == 0) {
                    return { .iterator = std::nullopt, .count = 0 };
                }

                auto count = array.size();
                auto* iter = JSPropertyIterator::create(vm, array.releaseData());
                if (!iter) {
                    throwOutOfMemoryError(globalObject, scope);
                    return {};
                }
                iter->isSpecialProxy = true;
                return { .iterator = iter, .count = count };
            }
        }
    }
#endif

    if (args.ownPropertiesOnly) {
        if (args.onlyNonIndexProperties) {
            object->getOwnNonIndexPropertyNames(globalObject, array, DontEnumPropertiesMode::Exclude);
        } else {
            object->methodTable()->getOwnPropertyNames(object, globalObject, array, DontEnumPropertiesMode::Exclude);
        }
    } else {
        object->getPropertyNames(globalObject, array, DontEnumPropertiesMode::Exclude);
    }
    RETURN_IF_EXCEPTION(scope, {});

    if (array.size() == 0) {
        return { .iterator = std::nullopt, .count = 0 };
    }

    auto count = array.size();
    auto* iter = JSPropertyIterator::create(vm, array.releaseData());
    if (!iter) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    return { .iterator = iter, .count = count };
}

size_t Bindgen::Engine::bunBindgenEngine_property_iterators_propertyIteratorGetLongestPropertyName(
    EngineCallContext&,
    const BunBindgenEngine_property_iterators_propertyIteratorGetLongestPropertyName_Arguments& args)
{
    size_t longest = 0;
    for (const auto& prop : args.iterator->properties->propertyNameVector()) {
        if (prop.length() > longest) {
            longest = prop.length();
        }
    }

    return longest;
}

static std::optional<JSValue> getOwnProxyObject(JSPropertyIterator* iter, JSObject* object, const JSC::Identifier& prop)
{
    auto& vm = iter->vm;
    auto scope = DECLARE_THROW_SCOPE(vm);

    PropertySlot slot(object, PropertySlot::InternalMethodType::GetOwnProperty, nullptr);
    auto* globalObject = object->globalObject();
    bool found = object->methodTable()->getOwnPropertySlot(object, globalObject, prop, slot);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!found)
        return std::nullopt;

    JSValue result = slot.getValue(globalObject, prop);
    RETURN_IF_EXCEPTION(scope, std::nullopt);

    return result;
}

Bindgen::Engine::BunBindgenEngine_property_iterators_propertyIteratorGetNameAndValue_Return Bindgen::Engine::bunBindgenEngine_property_iterators_propertyIteratorGetNameAndValue(
    EngineCallContext& context,
    const BunBindgenEngine_property_iterators_propertyIteratorGetNameAndValue_Arguments& args)
{
    using Return = BunBindgenEngine_property_iterators_propertyIteratorGetNameAndValue_Return;
    using Entry = Return::value_type;
    auto* iter = args.iterator;
    auto* globalObject = &context.globalObject;
    auto* object = JSC::asObject(args.object);
    auto& vm = iter->vm;
    auto scope = DECLARE_THROW_SCOPE(vm);

    const auto& prop = iter->properties->propertyNameVector()[args.index];
    JSValue result;
    if (iter->isSpecialProxy) [[unlikely]] {
        auto proxyResult = getOwnProxyObject(iter, object, prop);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!proxyResult)
            return std::nullopt;
        result = *proxyResult;
    } else {
        PropertySlot slot(object, PropertySlot::InternalMethodType::Get);
        bool found = object->getPropertySlot(globalObject, prop, slot);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!found)
            return std::nullopt;

        result = slot.getValue(globalObject, prop);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    Entry entry {};
    entry.name = prop.string().string();
    entry.value = result;
    return entry;
}

Bindgen::Engine::BunBindgenEngine_property_iterators_propertyIteratorGetNameAndValueNonObservable_Return Bindgen::Engine::bunBindgenEngine_property_iterators_propertyIteratorGetNameAndValueNonObservable(
    EngineCallContext& context,
    const BunBindgenEngine_property_iterators_propertyIteratorGetNameAndValueNonObservable_Arguments& args)
{
    using Return = BunBindgenEngine_property_iterators_propertyIteratorGetNameAndValueNonObservable_Return;
    using Entry = Return::value_type;
    auto* iter = args.iterator;
    auto* globalObject = &context.globalObject;
    auto* object = JSC::asObject(args.object);
    auto& vm = iter->vm;
    auto scope = DECLARE_THROW_SCOPE(vm);

    const auto& prop = iter->properties->propertyNameVector()[args.index];
    JSValue result;
    if (iter->isSpecialProxy) [[unlikely]] {
        auto proxyResult = getOwnProxyObject(iter, object, prop);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!proxyResult)
            return std::nullopt;
        result = *proxyResult;
    } else {
        PropertySlot slot(object, PropertySlot::InternalMethodType::VMInquiry, vm.ptr());
        auto has = object->getNonIndexPropertySlot(globalObject, prop, slot);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!has || !slot.isCacheableValue() || slot.isTaintedByOpaqueObject())
            return std::nullopt;

        result = slot.getPureResult();
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    Entry entry {};
    entry.name = prop.string().string();
    entry.value = result;
    return entry;
}

void Bindgen::Engine::propertyIteratorRelease(JSPropertyIterator* iterator)
{
    delete iterator;
}

}
