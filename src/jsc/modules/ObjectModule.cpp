#include "ObjectModule.h"
#include <JavaScriptCore/ExceptionHelpers.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/Strong.h>
#include <wtf/FastMalloc.h>

namespace Zig {

using Generator = JSC::SyntheticSourceProvider::SyntheticSourceGenerator;

class ObjectModuleGenerator final : public Generator::Impl {
public:
    enum class Kind { ownProperties, json, defaultValue };

    ObjectModuleGenerator(JSC::VM& vm, JSC::JSValue value, Kind kind)
        : m_value(vm, value)
        , m_kind(kind)
    {
    }

    void call(JSC::JSGlobalObject* lexicalGlobalObject, JSC::Identifier,
        Vector<JSC::Identifier, 4>& exportNames, JSC::MarkedArgumentBuffer& exportValues) final
    {
        auto& vm = lexicalGlobalObject->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto append = [&](const JSC::Identifier& name, JSC::JSValue value) {
            if (!exportNames.tryAppend(name)) {
                JSC::throwOutOfMemoryError(lexicalGlobalObject, scope);
                return false;
            }
            exportValues.append(value);
            if (exportValues.hasOverflowed()) {
                JSC::throwOutOfMemoryError(lexicalGlobalObject, scope);
                return false;
            }
            return true;
        };

        if (m_kind == Kind::defaultValue) {
            if (!append(vm.propertyNames->defaultKeyword, m_value.get()))
                return;
            append(vm.propertyNames->__esModule, JSC::jsBoolean(true));
            return;
        }

        auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
        auto* object = m_value.get().getObject();
        RELEASE_ASSERT(object);
        JSC::PropertyNameArrayBuilder properties(vm, JSC::PropertyNameMode::Strings, JSC::PrivateSymbolMode::Exclude);
        if (m_kind == Kind::ownProperties)
            object->methodTable()->getOwnPropertyNames(object, globalObject, properties, JSC::DontEnumPropertiesMode::Exclude);
        else
            object->getPropertyNames(globalObject, properties, JSC::DontEnumPropertiesMode::Exclude);
        RETURN_IF_EXCEPTION(scope, void());

        if (m_kind == Kind::json && !append(vm.propertyNames->defaultKeyword, object))
            return;
        auto propertyData = properties.releaseData();
        for (const auto& name : propertyData->propertyNameVector()) {
            if (m_kind == Kind::json && name == vm.propertyNames->defaultKeyword)
                continue;
            auto value = object->get(globalObject, name);
            RETURN_IF_EXCEPTION(scope, void());
            if (!append(name, value))
                return;
        }
    }

private:
    JSC::Strong<JSC::Unknown> m_value;
    Kind m_kind;
};

static Generator createGenerator(JSC::JSGlobalObject* globalObject, JSC::JSValue value, ObjectModuleGenerator::Kind kind)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    void* allocation = nullptr;
    if (!WTF::tryFastMalloc(sizeof(ObjectModuleGenerator)).getValue(allocation)) {
        JSC::throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto* generator = new (NotNull, allocation) ObjectModuleGenerator(globalObject->vm(), value, kind);
    return WTF::adopt(static_cast<Generator::Impl*>(generator));
}

Generator generateObjectModuleSourceCode(JSC::JSGlobalObject* globalObject, JSC::JSObject* object)
{
    return createGenerator(globalObject, object, ObjectModuleGenerator::Kind::ownProperties);
}

Generator generateJSValueModuleSourceCode(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    auto kind = value.isObject() && !JSC::isJSArray(value)
        ? ObjectModuleGenerator::Kind::json : ObjectModuleGenerator::Kind::defaultValue;
    return createGenerator(globalObject, value, kind);
}

Generator generateJSValueExportDefaultObjectSourceCode(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    return createGenerator(globalObject, value, ObjectModuleGenerator::Kind::defaultValue);
}

} // namespace Zig
