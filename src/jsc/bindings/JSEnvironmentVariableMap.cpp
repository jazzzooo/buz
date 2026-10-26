#include "root.h"
#include "JSEnvironmentVariableMap.h"
#include "ZigGlobalObject.h"

#include "helpers.h"

#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSArrayInlines.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSStringInlines.h>
#include <JavaScriptCore/PropertyDescriptor.h>

#include "BunClientData.h"
#include "wtf/Compiler.h"
#include "wtf/Forward.h"
#include "wtf/TimeZone.h"
#include "wtf-bindings.h"
#include "WebCoreJSBuiltins.h"
#include "SchemaBindings.h"

using namespace JSC;

namespace Bun {

using namespace WebCore;

const ClassInfo JSEnvironmentVariableMap::s_info = { "Object"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSEnvironmentVariableMap) };

static bool isProxyEnvironmentVariable(PropertyName propertyName)
{
    if (propertyName.isSymbol())
        return false;
    auto name = StringView(propertyName.publicName());
    return name == "HTTP_PROXY"_s || name == "http_proxy"_s
        || name == "HTTPS_PROXY"_s || name == "https_proxy"_s
        || name == "NO_PROXY"_s || name == "no_proxy"_s;
}

static bool isRuntimeEnvironmentVariable(PropertyName propertyName)
{
    if (propertyName.isSymbol())
        return false;
    auto name = StringView(propertyName.publicName());
    return isProxyEnvironmentVariable(propertyName) || name == "TZ"_s
        || name == "NODE_TLS_REJECT_UNAUTHORIZED"_s || name == "BUN_CONFIG_VERBOSE_FETCH"_s;
}

static void applyRuntimeEnvironmentVariable(PropertyName propertyName, const String& value)
{
    auto name = StringView(propertyName.publicName());
    if (name == "NODE_TLS_REJECT_UNAUTHORIZED"_s) {
        Bindgen::ZigExports::bunBindgenZig_Process_setTLSRejectUnauthorizedValue(value != "0"_s && value != "false"_s);
    } else if (name == "BUN_CONFIG_VERBOSE_FETCH"_s) {
        Bindgen::ZigExports::bunBindgenZig_Process_setVerboseFetchValue(value == "1"_s || value == "true"_s ? 1 : value == "curl"_s ? 2 : 0);
    }
}

class ProxyEnvironmentUpdateScope {
public:
    explicit ProxyEnvironmentUpdateScope(ProxyEnvironmentUpdate* update)
        : m_update(update)
    {
    }

    ProxyEnvironmentUpdateScope(const ProxyEnvironmentUpdateScope&) = delete;
    ProxyEnvironmentUpdateScope& operator=(const ProxyEnvironmentUpdateScope&) = delete;
    ~ProxyEnvironmentUpdateScope() { finish(false); }

    void finish(bool commit)
    {
        if (!m_update)
            return;
        Bindgen::ZigExports::bunBindgenZig_BunObject_finishProxyEnvironmentVariable(m_update, commit);
        m_update = nullptr;
    }

private:
    ProxyEnvironmentUpdate* m_update;
};

bool JSEnvironmentVariableMap::defineOwnProperty(JSObject* object, JSGlobalObject* globalObject, PropertyName propertyName, const PropertyDescriptor& descriptor, bool shouldThrow)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (!isRuntimeEnvironmentVariable(propertyName))
        RELEASE_AND_RETURN(scope, Base::defineOwnProperty(object, globalObject, propertyName, descriptor, shouldThrow));
    if (descriptor.isAccessorDescriptor()) {
        if (shouldThrow)
            throwTypeError(globalObject, scope, "Environment variables require data properties"_s);
        return false;
    }

    JSValue value = descriptor.value();
    if (!value) {
        PropertyDescriptor previous;
        bool own = object->getOwnPropertyDescriptor(globalObject, propertyName, previous);
        RETURN_IF_EXCEPTION(scope, false);
        if (own)
            RELEASE_AND_RETURN(scope, Base::defineOwnProperty(object, globalObject, propertyName, descriptor, shouldThrow));
        value = jsUndefined();
    }
    auto* string = value.toString(globalObject);
    RETURN_IF_EXCEPTION(scope, false);
    auto nativeString = string->value(globalObject);
    RETURN_IF_EXCEPTION(scope, false);
    PreparedTimeZoneOverride timeZone;
    bool hasTimeZone = false;
    if (StringView(propertyName.publicName()) == "TZ"_s) {
        auto result = timeZone.prepare(nativeString.data);
        if (result == PreparedTimeZoneOverride::Result::OutOfMemory) {
            throwOutOfMemoryError(globalObject, scope);
            return false;
        }
        hasTimeZone = result == PreparedTimeZoneOverride::Result::Valid;
    }
    PropertyDescriptor converted = descriptor;
    converted.setValue(string);
    auto* global = defaultGlobalObject(globalObject);
    ProxyEnvironmentUpdateScope update(isProxyEnvironmentVariable(propertyName)
            ? Bindgen::ZigExports::bunBindgenZig_BunObject_prepareProxyEnvironmentVariable(global, String(propertyName.publicName()), nativeString.data)
            : nullptr);
    RETURN_IF_EXCEPTION(scope, false);
    bool defined = Base::defineOwnProperty(object, globalObject, propertyName, converted, shouldThrow);
    RETURN_IF_EXCEPTION(scope, false);
    update.finish(defined);
    if (defined) {
        if (hasTimeZone) {
            timeZone.commit();
            WTF::timeZoneDidChange();
            globalObject->vm().dateCache.clearForTimeZoneChange();
        }
        applyRuntimeEnvironmentVariable(propertyName, nativeString.data);
    }
    return defined;
}

bool JSEnvironmentVariableMap::put(JSCell* cell, JSGlobalObject* globalObject, PropertyName propertyName, JSValue value, PutPropertySlot& slot)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (!isRuntimeEnvironmentVariable(propertyName) || slot.thisValue() != cell)
        RELEASE_AND_RETURN(scope, Base::put(cell, globalObject, propertyName, value, slot));
    auto* object = asObject(cell);
    auto* string = value.toString(globalObject);
    RETURN_IF_EXCEPTION(scope, false);
    PropertyDescriptor previous;
    bool own = object->getOwnPropertyDescriptor(globalObject, propertyName, previous);
    RETURN_IF_EXCEPTION(scope, false);
    if (own && !previous.writable()) {
        if (slot.isStrictMode())
            throwTypeError(globalObject, scope, "Cannot assign to a read-only environment variable"_s);
        return false;
    }
    PropertyDescriptor descriptor;
    if (own)
        descriptor.setValue(string);
    else
        descriptor = PropertyDescriptor(string, 0);
    RELEASE_AND_RETURN(scope, defineOwnProperty(object, globalObject, propertyName, descriptor, slot.isStrictMode()));
}

bool JSEnvironmentVariableMap::deleteProperty(JSCell* cell, JSGlobalObject* globalObject, PropertyName propertyName, DeletePropertySlot& slot)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (!isRuntimeEnvironmentVariable(propertyName))
        RELEASE_AND_RETURN(scope, Base::deleteProperty(cell, globalObject, propertyName, slot));
    auto* global = defaultGlobalObject(globalObject);
    ProxyEnvironmentUpdateScope update(isProxyEnvironmentVariable(propertyName)
            ? Bindgen::ZigExports::bunBindgenZig_BunObject_prepareProxyEnvironmentVariable(global, String(propertyName.publicName()), std::nullopt)
            : nullptr);
    RETURN_IF_EXCEPTION(scope, false);
    bool deleted = Base::deleteProperty(cell, globalObject, propertyName, slot);
    RETURN_IF_EXCEPTION(scope, false);
    update.finish(deleted);
    if (deleted) {
        if (StringView(propertyName.publicName()) == "TZ"_s) {
            PreparedTimeZoneOverride timeZone;
            auto result = timeZone.prepare(emptyString());
            RELEASE_ASSERT(result == PreparedTimeZoneOverride::Result::Valid);
            timeZone.commit();
            WTF::timeZoneDidChange();
            globalObject->vm().dateCache.clearForTimeZoneChange();
        }
        applyRuntimeEnvironmentVariable(propertyName, emptyString());
    }
    return deleted;
}

static std::optional<WTF::String> environmentVariableValue(JSGlobalObject* globalObject, PropertyName propertyName)
{
    auto* name = propertyName.publicName();
    if (!name) return std::nullopt;
    return Bindgen::ZigExports::bunBindgenZig_BunObject_environmentVariableGet(defaultGlobalObject(globalObject), WTF::String(name));
}

JSC_DEFINE_CUSTOM_GETTER(jsGetterEnvironmentVariable, (JSGlobalObject * globalObject, JSC::EncodedJSValue thisValue, PropertyName propertyName))
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* thisObject = dynamicDowncast<JSObject>(JSValue::decode(thisValue));
    if (!thisObject) [[unlikely]]
        return JSValue::encode(jsUndefined());

    auto value = environmentVariableValue(globalObject, propertyName);
    RETURN_IF_EXCEPTION(scope, {});
    if (!value) {
        return JSValue::encode(jsUndefined());
    }

    JSValue result = jsString(vm, *value);
    RETURN_IF_EXCEPTION(scope, {});
    thisObject->putDirect(vm, propertyName, result, 0);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(result);
}

JSValue createEnvironmentVariablesMap(Zig::GlobalObject* globalObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    size_t count = Bindgen::ZigExports::bunBindgenZig_BunObject_environmentVariableCount(globalObject);
    auto* object = JSEnvironmentVariableMap::create(vm, globalObject, globalObject->objectPrototype());

#if OS(WINDOWS)
    JSArray* keyArray = constructEmptyArray(globalObject, nullptr, count);
    RETURN_IF_EXCEPTION(scope, {});
#endif

    auto* cached_getter_setter = JSC::CustomGetterSetter::create(vm, jsGetterEnvironmentVariable, nullptr);

    for (size_t i = 0; i < count; i++) {
        auto maybeName = Bindgen::ZigExports::bunBindgenZig_BunObject_environmentVariableKey(globalObject, i);
        RETURN_IF_EXCEPTION(scope, {});
        if (!maybeName || maybeName->isEmpty()) continue;
        auto name = WTF::move(*maybeName);
#if OS(WINDOWS)
        keyArray->putByIndexInline(globalObject, (unsigned)i, jsString(vm, name), false);
#endif
#if OS(WINDOWS)
        String idName = name.convertToASCIIUppercase();
#else
        String idName = name;
#endif
        Identifier identifier = Identifier::fromString(vm, idName);

        if (isRuntimeEnvironmentVariable(identifier)) {
            auto valueString = Bindgen::ZigExports::bunBindgenZig_BunObject_environmentVariableGet(globalObject, name);
            RETURN_IF_EXCEPTION(scope, {});
            if (valueString) {
                auto* value = jsString(vm, *valueString);
                RETURN_IF_EXCEPTION(scope, {});
                object->putDirect(vm, identifier, value, 0);
                RETURN_IF_EXCEPTION(scope, {});
            }
            continue;
        }

        // CustomGetterSetter doesn't support indexed properties yet.
        // This causes strange issues when the environment variable name is an integer.
        if (name[0] >= '0' && name[0] <= '9') [[unlikely]] {
            if (auto index = parseIndex(identifier)) {
                auto valueString = Bindgen::ZigExports::bunBindgenZig_BunObject_environmentVariableGet(globalObject, name);
                RETURN_IF_EXCEPTION(scope, {});
                if (valueString) {
                    JSValue value = jsString(vm, *valueString);
                    RETURN_IF_EXCEPTION(scope, {});
                    object->putDirectIndex(globalObject, *index, value, 0, PutDirectIndexLikePutDirect);
                    RETURN_IF_EXCEPTION(scope, {});
                }
                continue;
            }
        }

        // JSC::PropertyAttribute::CustomValue calls the getter ONCE (the first
        // time) and then sets it onto the object, subsequent calls to the
        // getter will not go through the getter and instead will just do the
        // property lookup.
        object->putDirectCustomAccessor(vm, identifier, cached_getter_setter, JSC::PropertyAttribute::CustomValue | 0);
    }

#if OS(WINDOWS)
    auto editWindowsEnvVar = JSC::JSFunction::create(vm, globalObject, 0, String("editWindowsEnvVar"_s), bun_bindgen_host_RuntimeFunctions_jsEditWindowsEnvVar, ImplementationVisibility::Public);

    JSC::JSFunction* getSourceEvent = JSC::JSFunction::create(vm, globalObject, processObjectInternalsWindowsEnvCodeGenerator(vm), globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    JSC::MarkedArgumentBuffer args;
    args.append(object);
    args.append(keyArray);
    args.append(editWindowsEnvVar);
    JSC::CallData callData = JSC::getCallData(getSourceEvent);
    auto result = JSC::profiledCall(globalObject, JSC::ProfilingReason::API, getSourceEvent, callData, globalObject->globalThis(), args);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, result);
#else
    return object;
#endif
}
}

namespace Bun::Bindgen::Engine {

void releaseProxyEnvironmentUpdate(Bun::ProxyEnvironmentUpdate* update)
{
    ZigExports::bunBindgenZig_BunObject_finishProxyEnvironmentVariable(update, false);
}

}

#if OS(WINDOWS)
void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsEditWindowsEnvVar(
    CppCallContext&,
    const BunBindgenCpp_RuntimeFunctions_jsEditWindowsEnvVar_Arguments& args)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_Process_editWindowsEnvVar(args.name, args.value);
}
#endif
