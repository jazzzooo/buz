#include "root.h"

#include "BindingAssertions.h"
#include "BunClientData.h"
#include "FetchHeaders.h"
#include "JSFetchHeaders.h"
#include "ObjectBindings.h"
#include "SchemaBindings.h"
#include "WebCoreJSBuiltins.h"
#include "blob.h"
#include "helpers.h"
#include <JavaScriptCore/AggregateError.h>
#include <JavaScriptCore/Identifier.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSBigInt.h>
#include <JavaScriptCore/JSGlobalObjectInlines.h>
#include <JavaScriptCore/JSGlobalProxy.h>
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSSet.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSWeakMap.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/VMInlines.h>
#include <algorithm>
#include <limits>
#include <optional>
#include <wtf/text/StringCommon.h>

using namespace JSC;
using namespace WebCore;

namespace Bun::Bindgen::Custom {

PropertyKeyResult bunBindgenToPropertyKey(JSC::JSGlobalObject& global, JSC::JSValue value, WTF::ASCIILiteral)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto key = value.toPropertyKey(&global);
    RETURN_IF_EXCEPTION(scope, {});
    PropertyKeyResult result;
    if (key.isSymbol()) {
        auto symbol = identifierToJSValue(global.vm(), key);
        RETURN_IF_EXCEPTION(scope, {});
        result.set_symbol(symbol);
    } else {
        result.set_string(key.string());
    }
    return result;
}

}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_ExprJSC_createArrayLiteral(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_ExprJSC_createArrayLiteral_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (args.length > std::numeric_limits<uint32_t>::max()) {
        JSC::throwRangeError(&context.globalObject, scope, "Invalid array length"_s);
        return {};
    }
    RELEASE_AND_RETURN(scope, JSC::constructEmptyArray(&context.globalObject, nullptr, static_cast<uint32_t>(args.length)));
}

void Bun::Bindgen::Engine::bunBindgenEngine_ExprJSC_defineNextArrayLiteralElement(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_ExprJSC_defineNextArrayLiteralElement_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* array = dynamicDowncast<JSC::JSArray>(args.array);
    RELEASE_ASSERT(array);
    RELEASE_ASSERT(args.index < array->length());
    RELEASE_ASSERT(!array->getDirectIndex(&context.globalObject, args.index));
    RELEASE_ASSERT(args.index == 0 || array->getDirectIndex(&context.globalObject, args.index - 1));
    array->putDirectIndex(&context.globalObject, args.index, args.value);
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_ExprJSC_createObjectLiteral(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_ExprJSC_createObjectLiteral_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::constructEmptyObject(&context.globalObject, context.globalObject.objectPrototype(), std::min(static_cast<unsigned>(args.capacity), JSC::JSFinalObject::maxInlineCapacity)));
}

void Bun::Bindgen::Engine::bunBindgenEngine_ExprJSC_defineObjectLiteralProperty(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_ExprJSC_defineObjectLiteralProperty_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto key = args.key.toPropertyKey(&context.globalObject);
    RETURN_IF_EXCEPTION(scope, );
    auto* object = args.object.getObject();
    RELEASE_ASSERT(object);
    object->putDirectMayBeIndex(&context.globalObject, key, args.value);
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

static JSC::JSArray* loggerMessageArrayForNextElement(
    Bun::Bindgen::EngineCallContext& context,
    JSC::JSValue value,
    uint32_t index)
{
    auto* array = dynamicDowncast<JSC::JSArray>(value);
    RELEASE_ASSERT(array);
    RELEASE_ASSERT(index < array->length());
    RELEASE_ASSERT(!array->getDirectIndex(&context.globalObject, index));
    RELEASE_ASSERT(index == 0 || array->getDirectIndex(&context.globalObject, index - 1));
    return array;
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_LoggerJSC_createMessageArray(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_LoggerJSC_createMessageArray_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (args.length > std::numeric_limits<uint32_t>::max()) {
        JSC::throwOutOfMemoryError(&context.globalObject, scope);
        return {};
    }
    RELEASE_AND_RETURN(scope, JSC::constructEmptyArray(&context.globalObject, nullptr, static_cast<uint32_t>(args.length)));
}

void Bun::Bindgen::Engine::bunBindgenEngine_LoggerJSC_appendBuildMessage(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_LoggerJSC_appendBuildMessage_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* array = loggerMessageArrayForNextElement(context, args.array, args.index);
    array->putDirectIndex(&context.globalObject, args.index, context.classValue(args.message));
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

void Bun::Bindgen::Engine::bunBindgenEngine_LoggerJSC_appendResolveMessage(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_LoggerJSC_appendResolveMessage_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* array = loggerMessageArrayForNextElement(context, args.array, args.index);
    array->putDirectIndex(&context.globalObject, args.index, context.classValue(args.message));
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_LoggerJSC_createAggregateError(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_LoggerJSC_createAggregateError_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* structure = globalObject.errorStructure(JSC::ErrorType::AggregateError);
    RELEASE_AND_RETURN(scope, JSC::createAggregateError(vm, structure, uncheckedDowncast<JSC::JSArray>(args.errors), args.message, JSC::jsUndefined(), nullptr, JSC::TypeNothing, false));
}

bool Bun::Bindgen::Engine::bunBindgenEngine_property_accessors_jsValueHasOwnProperty(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_property_accessors_jsValueHasOwnProperty_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* object = args.object.getObject();
    RELEASE_ASSERT(object);
    auto propertyKey = args.key.toPropertyKey(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    const bool result = JSC::objectPrototypeHasOwnProperty(globalObject, object, propertyKey);
    RETURN_IF_EXCEPTION(scope, {});

    return result;
}

std::optional<double> Bun::Bindgen::Engine::bunBindgenEngine_js_value_inspection_jsValueLengthIfPropertyExists(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_js_value_inspection_jsValueLengthIfPropertyExists_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto jsValue = args.value;
    if (!jsValue || !jsValue.isCell())
        return std::nullopt;
    JSCell* cell = jsValue.asCell();
    JSC::JSType type = cell->type();

    if (auto* wrapper = dynamicDowncast<WebCore::JSFetchHeaders>(cell)) {
        auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
        auto headers = WebCore::protectedFetchHeaders(globalObject, wrapper);
        RETURN_IF_EXCEPTION(scope, 0);
        RELEASE_ASSERT(headers);
        return static_cast<double>(headers->size());
    }

    if (auto blob = WebCore::Blob::retain(jsValue)) {
        auto size = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobGetSizeForBindings(blob.get());
        if (!size)
            return std::nullopt;
        return static_cast<double>(*size);
    }

    switch (static_cast<uint8_t>(type)) {
    case JSC::JSType::StringType:
        return static_cast<double>(jsValue.toString(globalObject)->length());
    case JSC::JSType::ArrayType:
        return static_cast<double>(uncheckedDowncast<JSC::JSArray>(cell)->length());

    case JSC::JSType::Int8ArrayType:
    case JSC::JSType::Uint8ArrayType:
    case JSC::JSType::Uint8ClampedArrayType:
    case JSC::JSType::Int16ArrayType:
    case JSC::JSType::Uint16ArrayType:
    case JSC::JSType::Int32ArrayType:
    case JSC::JSType::Uint32ArrayType:
    case JSC::JSType::Float16ArrayType:
    case JSC::JSType::Float32ArrayType:
    case JSC::JSType::Float64ArrayType:
    case JSC::JSType::BigInt64ArrayType:
    case JSC::JSType::BigUint64ArrayType:
        return static_cast<double>(uncheckedDowncast<JSC::JSArrayBufferView>(cell)->length());

    case JSC::JSType::JSMapType:
        return static_cast<double>(uncheckedDowncast<JSC::JSMap>(cell)->size());

    case JSC::JSType::JSSetType:
        return static_cast<double>(uncheckedDowncast<JSC::JSSet>(cell)->size());

    case JSC::JSType::JSWeakMapType:
        return static_cast<double>(uncheckedDowncast<JSC::JSWeakMap>(cell)->size());

    case JSC::JSType::ArrayBufferType: {
        auto* arrayBuffer = uncheckedDowncast<JSC::JSArrayBuffer>(cell);
        if (auto* impl = arrayBuffer->impl()) {
            return static_cast<double>(impl->byteLength());
        }

        return 0;
    }

    default: {

        if (auto* object = dynamicDowncast<JSObject>(cell)) {
            auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
            JSValue lengthValue = object->getIfPropertyExists(globalObject, globalObject->vm().propertyNames->length);
            RETURN_IF_EXCEPTION(scope, 0);
            if (lengthValue)
                RELEASE_AND_RETURN(scope, lengthValue.toNumber(globalObject));
            scope.release();
        }
    }
    }

    return std::nullopt;
}

uint8_t Bun::Bindgen::Engine::bunBindgenEngine_bigints_jsValueCompareBigInt(
    Bun::Bindgen::EngineCallContext&,
    const Bun::Bindgen::Engine::BunBindgenEngine_bigints_jsValueCompareBigInt_Arguments& args)
{
    JSValue v1 = args.left;
    JSValue v2 = args.right;
    ASSERT(v1.isHeapBigInt() || v1.isBigInt32());

#if USE(BIGINT32)
    if (v1.isBigInt32()) {
        int32_t v1Int = v1.bigInt32AsInt32();
        if (v2.isHeapBigInt()) {
            return static_cast<uint8_t>(JSBigInt::compare(v1Int, v2.asHeapBigInt()));
        } else if (v2.isBigInt32()) {
            return static_cast<uint8_t>(JSBigInt::compare(v1Int, v2.bigInt32AsInt32()));
        }

        double v2Double = v2.asNumber();
        if (v1Int == v2Double) {
            return static_cast<uint8_t>(JSBigInt::ComparisonResult::Equal);
        }
        if (v1Int < v2Double) {
            return static_cast<uint8_t>(JSBigInt::ComparisonResult::LessThan);
        }

        return static_cast<uint8_t>(JSBigInt::ComparisonResult::GreaterThan);
    }
#endif

    if (v1.isHeapBigInt()) {
        JSBigInt* v1BigInt = v1.asHeapBigInt();
        if (v2.isHeapBigInt()) {
            return static_cast<uint8_t>(JSBigInt::compare(v1BigInt, v2.asHeapBigInt()));
        }

#if USE(BIGINT32)
        if (v2.isBigInt32()) {
            return static_cast<uint8_t>(JSBigInt::compare(v1BigInt, v2.bigInt32AsInt32()));
        }
#endif

        return static_cast<uint8_t>(JSBigInt::compareToDouble(v1BigInt, v2.asNumber()));
    }

    ASSERT_NOT_REACHED();
    return static_cast<uint8_t>(JSBigInt::ComparisonResult::Undefined);
}

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_property_accessors_getIfPropertyExists(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_property_accessors_getIfPropertyExists_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    Bun::assertNoPendingException(globalObject);
    ASSERT_WITH_MESSAGE(!args.target.isEmpty(), "get() must not be called on empty value");

    auto& vm = JSC::getVM(globalObject);
    JSC::JSObject* object = args.target.getObject();
    if (!object) [[unlikely]]
        return std::nullopt;

    const auto identifier = JSC::Identifier::fromString(vm, args.property);
    const auto property = JSC::PropertyName(identifier);
    auto result = Bun::getIfPropertyExistsPrototypePollutionMitigationUnsafe(vm, globalObject, object, property);
    if (!result || result.isUndefined() || result == JSValue::decode(JSC::JSValue::ValueDeleted))
        return std::nullopt;
    return result;
}

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_property_accessors_jsValueGetIfPropertyExistsFromPath(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_property_accessors_jsValueGetIfPropertyExistsFromPath_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);
    JSValue value = args.value;
    const auto& path = args.path;

    if (path.is_string()) {
        String pathString = path.string().toWTFString(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        uint32_t length = pathString.length();

        if (length == 0) {
            auto* valueObject = value.toObject(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            JSValue prop = valueObject->getIfPropertyExists(globalObject, vm.propertyNames->emptyIdentifier);
            RETURN_IF_EXCEPTION(scope, {});
            return prop ? std::optional<JSValue>(prop) : std::nullopt;
        }

        // Jest doesn't check for valid dot/bracket notation. It will skip all "[" and "]", and search for
        // an empty string for "." when it's the first or last character of the path, or if there are
        // two in a row.

        JSValue currProp = value;
        uint32_t i = 0;
        uint32_t j = 0;

        // if "." is the only character, it will search for an empty string twice.
        if (pathString.codeUnitAt(0) == '.') {
            auto* currPropObject = currProp.toObject(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            currProp = currPropObject->getIfPropertyExists(globalObject, vm.propertyNames->emptyIdentifier);
            RETURN_IF_EXCEPTION(scope, {});
            if (currProp.isEmpty()) {
                return std::nullopt;
            }
        }

        while (i < length) {
            char16_t ic = pathString.codeUnitAt(i);
            while (ic == '[' || ic == ']' || ic == '.') {
                i += 1;
                if (i == length) {

                    if (ic == '.') {
                        auto* currPropObject = currProp.toObject(globalObject);
                        RETURN_IF_EXCEPTION(scope, {});
                        currProp = currPropObject->getIfPropertyExists(globalObject, vm.propertyNames->emptyIdentifier);
                        RETURN_IF_EXCEPTION(scope, {});
                        return currProp ? std::optional<JSValue>(currProp) : std::nullopt;
                    }

                    // nothing found.
                    if (j == 0) {
                        return {};
                    }

                    return currProp;
                }

                char16_t previous = ic;
                ic = pathString.codeUnitAt(i);
                if (previous == '.' && ic == '.') {
                    auto* currPropObject = currProp.toObject(globalObject);
                    RETURN_IF_EXCEPTION(scope, {});
                    currProp = currPropObject->getIfPropertyExists(globalObject, vm.propertyNames->emptyIdentifier);
                    RETURN_IF_EXCEPTION(scope, {});
                    if (currProp.isEmpty()) {
                        return std::nullopt;
                    }
                    continue;
                }
            }

            j = i;
            char16_t jc = pathString.codeUnitAt(j);
            while (!(jc == '[' || jc == ']' || jc == '.')) {
                j += 1;
                if (j == length) {
                    // break and search for property
                    break;
                }
                jc = pathString.codeUnitAt(j);
            }

            String propNameStr = pathString.substring(i, j - i);
            PropertyName propName = PropertyName(Identifier::fromString(vm, propNameStr));

            auto* currPropObject = currProp.toObject(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            currProp = currPropObject->getIfPropertyExists(globalObject, propName);
            RETURN_IF_EXCEPTION(scope, {});
            if (currProp.isEmpty()) {
                return std::nullopt;
            }

            i = j;
        }

        return currProp;
    }

    if (path.is_array()) {
        // each item in array is property name, ignore dot/bracket notation
        JSValue currProp = value;
        auto* pathObject = uncheckedDowncast<JSArray>(path.array());
        forEachInArrayLike(globalObject, pathObject, [&](JSValue item) -> bool {
            if (!(item.isString() || item.isNumber())) {
                currProp = {};
                return false;
            }

            JSString* propNameString = item.toString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            PropertyName propName = PropertyName(propNameString->toIdentifier(globalObject));
            RETURN_IF_EXCEPTION(scope, {});

            auto* currPropObject = currProp.toObject(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            currProp = currPropObject->getIfPropertyExists(globalObject, propName);
            RETURN_IF_EXCEPTION(scope, {});
            if (currProp.isEmpty()) {
                return false;
            }

            return true;
        });
        RETURN_IF_EXCEPTION(scope, {});
        return currProp ? std::optional<JSValue>(currProp) : std::nullopt;
    }

    RELEASE_ASSERT_NOT_REACHED();
}

template<typename BuiltinName>
static inline const JSC::Identifier& builtinNameMap(JSC::VM& vm, BuiltinName name)
{

    auto clientData = WebCore::clientData(vm);
    switch (name) {
    case BuiltinName::method: {
        return clientData->builtinNames().methodPublicName();
    }
    case BuiltinName::headers: {
        return clientData->builtinNames().headersPublicName();
    }
    case BuiltinName::statusText: {
        return clientData->builtinNames().statusTextPublicName();
    }
    case BuiltinName::status: {
        return clientData->builtinNames().statusPublicName();
    }
    case BuiltinName::url: {
        return clientData->builtinNames().urlPublicName();
    }
    case BuiltinName::body: {
        return clientData->builtinNames().bodyPublicName();
    }
    case BuiltinName::data: {
        return clientData->builtinNames().dataPublicName();
    }
    case BuiltinName::toString: {
        return vm.propertyNames->toString;
    }
    case BuiltinName::redirect: {
        return clientData->builtinNames().redirectPublicName();
    }
    case BuiltinName::inspectCustom: {
        return clientData->builtinNames().inspectCustomPublicName();
    }
    case BuiltinName::highWaterMark: {
        return clientData->builtinNames().highWaterMarkPublicName();
    }
    case BuiltinName::path: {
        return clientData->builtinNames().pathPublicName();
    }
    case BuiltinName::stream: {
        return clientData->builtinNames().streamPublicName();
    }
    case BuiltinName::asyncIterator: {
        return vm.propertyNames->asyncIteratorSymbol;
    }
    case BuiltinName::name: {
        return vm.propertyNames->name;
    }
    case BuiltinName::message: {
        return vm.propertyNames->message;
    }
    case BuiltinName::error: {
        return vm.propertyNames->error;
    }
    case BuiltinName::defaultKeyword: {
        return vm.propertyNames->defaultKeyword;
    }
    case BuiltinName::encoding: {
        return clientData->builtinNames().encodingPublicName();
    }
    case BuiltinName::fatal: {
        return clientData->builtinNames().fatalPublicName();
    }
    case BuiltinName::ignoreBOM: {
        return clientData->builtinNames().ignoreBOMPublicName();
    }
    case BuiltinName::type: {
        return vm.propertyNames->type;
    }
    case BuiltinName::signal: {
        return clientData->builtinNames().signalPublicName();
    }
    case BuiltinName::cmd: {
        return clientData->builtinNames().cmdPublicName();
    }
    default: {
        ASSERT_NOT_REACHED();
        __builtin_unreachable();
    }
    }
}

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_property_accessors_jsValueFastGet(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_property_accessors_jsValueFastGet_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    JSC::JSObject* object = args.value.getObject();
    RELEASE_ASSERT(object);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    const auto property = JSC::PropertyName(builtinNameMap(vm, args.builtinId));
    auto result = Bun::getIfPropertyExistsPrototypePollutionMitigationUnsafe(vm, globalObject, object, property);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (JSC::JSValue::encode(result) == JSC::JSValue::ValueDeleted || result.isUndefined()) {
        scope.release();
        return std::nullopt;
    }
    RELEASE_AND_RETURN(scope, std::optional<JSC::JSValue> { result });
}

namespace Bun {

class ConsolePropertyIterator {
public:
    ConsolePropertyIterator(JSC::VM& vm, RefPtr<JSC::PropertyNameArray>&& properties)
        : vm(vm)
        , properties(WTF::move(properties))
    {
    }

    static ConsolePropertyIterator* create(JSC::VM& vm, RefPtr<JSC::PropertyNameArray>&& properties)
    {
        return new ConsolePropertyIterator(vm, WTF::move(properties));
    }

    Ref<JSC::VM> vm;
    RefPtr<JSC::PropertyNameArray> properties;

    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(ConsolePropertyIterator);
};

}

static WTF::String consolePropertyName(const JSC::Identifier& property)
{
    auto* impl = property.isSymbol() && !property.isPrivateName() ? property.impl() : property.string().impl();
    return WTF::String(impl);
}

Bun::Bindgen::Engine::BunBindgenEngine_property_iterators_consolePropertyIteratorCreate_Return Bun::Bindgen::Engine::bunBindgenEngine_property_iterators_consolePropertyIteratorCreate(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_property_iterators_consolePropertyIteratorCreate_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* object = args.value.getObject();
    if (!object)
        return {};

    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!vm.isSafeToRecurse()) [[unlikely]] {
        throwStackOverflowError(globalObject, scope);
        return {};
    }

    auto privateSymbolMode = JSC::Options::showPrivateScriptsInStackTraces()
        ? PrivateSymbolMode::Include
        : PrivateSymbolMode::Exclude;
    JSC::PropertyNameArrayBuilder properties(vm, PropertyNameMode::StringsAndSymbols, privateSymbolMode);

    switch (args.mode) {
    case decltype(args.mode)::all: {
        size_t prototypeCount = 0;
        JSObject* iterating = object;
        while (iterating
            && iterating != globalObject->objectPrototype()
            && iterating != globalObject->functionPrototype()
            && !(iterating->inherits<JSGlobalProxy>() && uncheckedDowncast<JSGlobalProxy>(iterating)->target() != globalObject)
            && prototypeCount++ < 5) {
            iterating->methodTable()->getOwnPropertyNames(
                iterating,
                globalObject,
                properties,
                DontEnumPropertiesMode::Include);
            RETURN_IF_EXCEPTION(scope, {});

            if (iterating->isCallable() || iterating == globalObject)
                break;

            auto prototype = iterating->getPrototype(globalObject);
            if (scope.exception()) [[unlikely]] {
                (void)scope.tryClearException();
                break;
            }
            iterating = prototype.getObject();
        }
        break;
    }
    case decltype(args.mode)::nonIndexed:
        object->getOwnNonIndexPropertyNames(globalObject, properties, DontEnumPropertiesMode::Include);
        RETURN_IF_EXCEPTION(scope, {});
        break;
    case decltype(args.mode)::ordered:
        JSC::JSObject::getOwnPropertyNames(object, globalObject, properties, DontEnumPropertiesMode::Include);
        if (scope.exception()) [[unlikely]] {
            (void)scope.tryClearException();
            return {};
        }
        break;
    }

    auto& names = properties.data()->propertyNameVector();
    auto& builtinNames = WebCore::builtinNames(vm);
    names.removeAllMatching([&](const Identifier& property) {
        if (property.isNull())
            return true;
        if (property == vm.propertyNames->constructor || property == builtinNames.bunNativePtrPrivateName())
            return true;
        return args.mode == decltype(args.mode)::nonIndexed && property == vm.propertyNames->length;
    });

    if (args.mode == decltype(args.mode)::ordered) {
        std::sort(names.begin(), names.end(), [&](const Identifier& a, const Identifier& b) {
            const auto* aImpl = a.isSymbol() && !a.isPrivateName() ? a.impl() : a.string().impl();
            const auto* bImpl = b.isSymbol() && !b.isPrivateName() ? b.impl() : b.string().impl();
            return codePointCompare(aImpl, bImpl) < 0;
        });
    }

    if (names.isEmpty())
        return { .iterator = std::nullopt, .count = 0 };

    auto count = names.size();
    return {
        .iterator = Bun::ConsolePropertyIterator::create(vm, properties.releaseData()),
        .count = count,
    };
}

Bun::Bindgen::Engine::BunBindgenEngine_property_iterators_consolePropertyIteratorGetEntry_Return Bun::Bindgen::Engine::bunBindgenEngine_property_iterators_consolePropertyIteratorGetEntry(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_property_iterators_consolePropertyIteratorGetEntry_Arguments& args)
{
    using Return = BunBindgenEngine_property_iterators_consolePropertyIteratorGetEntry_Return;
    using Entry = Return::value_type;

    auto* globalObject = &context.globalObject;
    auto* object = args.value.getObject();
    if (!object || args.index >= args.iterator->properties->propertyNameVector().size())
        return std::nullopt;

    auto& vm = args.iterator->vm.get();
    auto scope = DECLARE_THROW_SCOPE(vm);
    const auto& property = args.iterator->properties->propertyNameVector()[args.index];

    JSC::PropertySlot slot(object, PropertySlot::InternalMethodType::Get);
    bool hasProperty = object->getPropertySlot(globalObject, property, slot);
    if (scope.exception()) [[unlikely]] {
        (void)scope.tryClearException();
        return std::nullopt;
    }
    if (!hasProperty)
        return std::nullopt;

    if ((slot.attributes() & PropertyAttribute::DontEnum) != 0
        && (property == vm.propertyNames->underscoreProto
            || property == vm.propertyNames->toStringTagSymbol
            || property == vm.propertyNames->__esModule))
        return std::nullopt;

    JSC::JSValue propertyValue = jsUndefined();
    if ((slot.attributes() & PropertyAttribute::DontEnum) != 0) {
        if ((slot.attributes() & PropertyAttribute::Accessor) != 0) {
            propertyValue = slot.isCacheableGetter() ? slot.getPureResult() : JSC::JSValue(slot.getterSetter());
        } else if (slot.attributes() & PropertyAttribute::BuiltinOrFunction) {
            propertyValue = slot.getValue(globalObject, property);
        } else if (slot.isCustom() || slot.isValue()) {
            propertyValue = slot.getValue(globalObject, property);
        } else if (object->getOwnPropertySlot(object, globalObject, property, slot)) {
            propertyValue = slot.getValue(globalObject, property);
        }
    } else if (slot.isAccessor()) {
        propertyValue = slot.isCacheableGetter() ? slot.getPureResult() : JSC::JSValue(slot.getterSetter());
    } else {
        propertyValue = slot.getValue(globalObject, property);
    }

    if (scope.exception()) [[unlikely]] {
        (void)scope.tryClearException();
        propertyValue = jsUndefined();
    } else if (!propertyValue) {
        propertyValue = jsUndefined();
    }

    Entry entry {};
    entry.name = consolePropertyName(property);
    entry.value = propertyValue;
    entry.isSymbol = property.isSymbol();
    entry.isPrivateSymbol = property.isPrivateName();
    return entry;
}

void Bun::Bindgen::Engine::bunBindgenEngine_property_iterators_consolePropertyIteratorDestroy(
    const BunBindgenEngine_property_iterators_consolePropertyIteratorDestroy_Arguments& args)
{
    delete args.iterator;
}
