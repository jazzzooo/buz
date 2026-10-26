#include "BindgenTypePredicates.h"

#include "BunProcess.h"
#include "BunBuiltinNames.h"
#include "JSAbortSignal.h"
#include "JSBuffer.h"
#include "JSBunRequest.h"
#include "JSCommonJSModule.h"
#include "JSDOMURL.h"
#include "ZigGlobalObject.h"
#include "webcore/JSFetchHeaders.h"

#include <JavaScriptCore/BigIntObject.h>
#include <JavaScriptCore/CallData.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/FunctionExecutable.h>
#include <JavaScriptCore/InternalFieldTuple.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSArrayBufferViewInlinesLight.h>
#include <JavaScriptCore/JSBoundFunction.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/ParserModes.h>
#include <JavaScriptCore/RegExpObject.h>
#include <JavaScriptCore/Structure.h>
#include <JavaScriptCore/SymbolObject.h>

namespace Bun::Bindgen::TypePredicates {

bool isException(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::Exception>(value);
}

static JSC::JSCell* cell(JSC::JSValue value) noexcept
{
    return value.isCell() ? value.asCell() : nullptr;
}

static bool hasType(JSC::JSValue value, JSC::JSType type) noexcept
{
    auto* candidate = cell(value);
    return candidate && candidate->type() == type;
}

bool isCommonJSModule(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::JSCommonJSModule>(value);
}

bool isBunRequest(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::JSBunRequest>(value);
}

bool isProcessObject(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::Process>(value);
}

bool isCallable(JSC::JSValue value) noexcept
{
    return value.isCallable();
}

bool isConstructor(JSC::JSValue value) noexcept
{
    return value.isConstructor();
}

bool isNumber(JSC::JSValue value) noexcept
{
    return value.isNumber();
}

bool isAnyInt(JSC::JSValue value) noexcept
{
    return value.isAnyInt();
}

bool isString(JSC::JSValue value) noexcept
{
    return value.isString();
}

bool isStringLike(JSC::JSValue value) noexcept
{
    return value.isString() || isStringObject(value);
}

bool isTypedArray(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::JSArrayBufferView>(value) && !hasType(value, JSC::DataViewType);
}

bool isNodeBuffer(JSC::JSValue value) noexcept
{
    return WebCore::isNodeBuffer(value);
}

bool isStringOrRegExp(JSC::JSValue value) noexcept
{
    return value.isString() || !!dynamicDowncast<JSC::RegExpObject>(value);
}

bool isNodeIPCMessage(JSC::JSValue value) noexcept
{
    return value.isString() || value.isObject() || value.isNumber() || value.isBoolean() || value.isNull();
}

bool isRedisResponseValue(JSC::JSValue value) noexcept
{
    return value.isString() || value.isNumber() || value.isBoolean() || value.isNull() || value.isObject();
}

bool isPresent(JSC::JSValue value) noexcept
{
    return !value.isEmpty();
}

bool isFetchHeaders(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<WebCore::JSFetchHeaders>(value);
}

bool isDOMURL(JSC::JSValue value) noexcept
{
    auto* url = dynamicDowncast<WebCore::JSDOMURL>(value);
    return url && url->native();
}

bool isDetachedBufferSource(JSC::JSValue value) noexcept
{
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value))
        return view->isDetached();
    if (auto* buffer = dynamicDowncast<JSC::JSArrayBuffer>(value))
        return buffer->impl()->isDetached();
    return false;
}

bool isFixedBufferSource(JSC::JSValue value) noexcept
{
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value))
        return !view->isResizableOrGrowableShared() && !view->isShared();
    if (auto* buffer = dynamicDowncast<JSC::JSArrayBuffer>(value))
        return !buffer->impl()->isResizableOrGrowableShared() && !buffer->impl()->isShared();
    return false;
}

bool isWasmBufferSource(JSC::JSValue value) noexcept
{
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
        if (!view->hasArrayBuffer())
            return false;
        auto* buffer = view->possiblySharedBuffer();
        return buffer && buffer->isWasmMemory();
    }
    if (auto* buffer = dynamicDowncast<JSC::JSArrayBuffer>(value))
        return buffer->impl()->isWasmMemory();
    return false;
}

bool isObject(JSC::JSValue value) noexcept
{
    return value.isObject();
}

bool isArray(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::JSArray>(value);
}

bool isCell(JSC::JSValue value) noexcept
{
    return value.isCell();
}

bool isStructure(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::Structure>(value);
}

bool isArrayBufferView(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::JSArrayBufferView>(value);
}

bool isInternalFieldTuple(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::InternalFieldTuple>(value);
}

bool isErrorInstance(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::ErrorInstance>(value);
}

bool isBoundFunction(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::JSBoundFunction>(value);
}

bool isBigInt(JSC::JSValue value) noexcept
{
    return value.isBigInt();
}

bool isBigIntOrNumber(JSC::JSValue value) noexcept
{
    return value.isBigInt() || value.isNumber();
}

bool isSymbol(JSC::JSValue value) noexcept
{
    return value.isSymbol();
}

bool isDate(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::JSDateType);
}

bool isArgumentsObject(JSC::JSValue value) noexcept
{
    auto* candidate = cell(value);
    if (!candidate)
        return false;
    switch (candidate->type()) {
    case JSC::DirectArgumentsType:
    case JSC::ScopedArgumentsType:
    case JSC::ClonedArgumentsType:
        return true;
    default:
        return false;
    }
}

bool isBigIntObject(JSC::JSValue value) noexcept
{
    return value.inherits<JSC::BigIntObject>();
}

bool isBooleanObject(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::BooleanObjectType);
}

bool isNumberObject(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::NumberObjectType);
}

bool isStringObject(JSC::JSValue value) noexcept
{
    auto* candidate = cell(value);
    return candidate && (candidate->type() == JSC::StringObjectType || candidate->type() == JSC::DerivedStringObjectType);
}

bool isSymbolObject(JSC::JSValue value) noexcept
{
    return value.inherits<JSC::SymbolObject>();
}

bool isRegExp(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::RegExpObjectType);
}

bool isAsyncFunction(JSC::JSValue value) noexcept
{
    auto* function = dynamicDowncast<JSC::JSFunction>(value);
    if (!function || function->isHostFunction())
        return false;
    auto* executable = function->jsExecutable();
    return executable && JSC::isAsyncFunctionOrAsyncGeneratorWrapperParseMode(executable->parseMode());
}

bool isGeneratorFunction(JSC::JSValue value) noexcept
{
    auto* function = dynamicDowncast<JSC::JSFunction>(value);
    if (!function || function->isHostFunction())
        return false;
    auto* executable = function->jsExecutable();
    return executable && (executable->isGenerator() || executable->isAsyncGenerator());
}

bool isGeneratorObject(JSC::JSValue value) noexcept
{
    auto* candidate = cell(value);
    return candidate && (candidate->type() == JSC::JSGeneratorType || candidate->type() == JSC::JSAsyncGeneratorType);
}

bool isPromise(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::JSPromiseType);
}

bool isMap(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::JSMapType);
}

bool isSet(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::JSSetType);
}

bool isMapIterator(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::JSMapIteratorType);
}

bool isSetIterator(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::JSSetIteratorType);
}

bool isWeakMap(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::JSWeakMapType);
}

bool isWeakSet(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::JSWeakSetType);
}

bool isArrayBuffer(JSC::JSValue value) noexcept
{
    auto* buffer = dynamicDowncast<JSC::JSArrayBuffer>(value);
    return buffer && !buffer->isShared();
}

bool isAnyArrayBuffer(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::JSArrayBuffer>(value);
}

bool isDataView(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::DataViewType);
}

bool isSharedArrayBuffer(JSC::JSValue value) noexcept
{
    auto* buffer = dynamicDowncast<JSC::JSArrayBuffer>(value);
    return buffer && buffer->isShared();
}

bool isProxy(JSC::JSValue value) noexcept
{
    auto* candidate = cell(value);
    return candidate && (candidate->type() == JSC::GlobalProxyType || candidate->type() == JSC::ProxyObjectType);
}

bool isModuleNamespaceObject(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::ModuleNamespaceObjectType);
}

bool isUint8Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Uint8ArrayType);
}

bool isUint8ClampedArray(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Uint8ClampedArrayType);
}

bool isUint16Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Uint16ArrayType);
}

bool isUint32Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Uint32ArrayType);
}

bool isInt8Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Int8ArrayType);
}

bool isInt16Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Int16ArrayType);
}

bool isInt32Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Int32ArrayType);
}

bool isFloat16Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Float16ArrayType);
}

bool isFloat32Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Float32ArrayType);
}

bool isFloat64Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::Float64ArrayType);
}

bool isBigInt64Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::BigInt64ArrayType);
}

bool isBigUint64Array(JSC::JSValue value) noexcept
{
    return hasType(value, JSC::BigUint64ArrayType);
}

bool isInternalWritableStream(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).writableStreamBrandPrivateName()).isTrue();
}

bool isReadableByteStreamController(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).byteControllerBrandPrivateName()).isTrue();
}

bool isReadableStreamDefaultController(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).defaultControllerBrandPrivateName()).isTrue();
}

bool isReadableStreamDefaultReader(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    auto requests = object->getDirect(vm, WebCore::builtinNames(vm).readRequestsPrivateName());
    return requests && requests.isObject();
}

bool isReadableStreamBYOBReader(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    auto requests = object->getDirect(vm, WebCore::builtinNames(vm).readIntoRequestsPrivateName());
    return requests && requests.isObject();
}

bool isReadableStreamBYOBRequest(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    auto controller = object->getDirect(vm, WebCore::builtinNames(vm).associatedReadableByteStreamControllerPrivateName());
    return controller && !controller.isUndefined();
}

bool isTransformStreamDefaultController(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).transformControllerBrandPrivateName()).isTrue();
}

bool isWritableStreamDefaultWriter(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    auto promise = object->getDirect(vm, WebCore::builtinNames(vm).closedPromisePrivateName());
    return promise && promise.isObject();
}

bool isWritableStreamDefaultController(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    auto abortSteps = object->getDirect(vm, WebCore::builtinNames(vm).abortStepsPrivateName());
    return abortSteps && !abortSteps.isUndefined();
}

bool isAbortSignal(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<WebCore::JSAbortSignal>(value);
}

bool isTextEncoder(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).textEncoderBrandPrivateName()).isTrue();
}

bool isPerformanceObserverEntryList(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return isArray(object->getDirect(vm, WebCore::builtinNames(vm).performanceObserverEntriesPrivateName()));
}

bool isReadableStreamIterator(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).readableStreamIteratorBrandPrivateName()).isTrue();
}

bool isPerformanceTiming(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).performanceTimingBrandPrivateName()).isTrue();
}

bool isNodeFSStatValue(JSC::JSGlobalObject&, JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).nodeFSStatBrandPrivateName()).isTrue();
}

bool isNodeFSStatFsValue(JSC::JSGlobalObject&, JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto& vm = object->vm();
    return object->getDirect(vm, WebCore::builtinNames(vm).nodeFSStatFsBrandPrivateName()).isTrue();
}

bool isMIMEParamsObject(JSC::JSGlobalObject& lexicalGlobalObject, JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto* globalObject = defaultGlobalObject(&lexicalGlobalObject);
    return object->structure() == globalObject->BunBindgen_MIMEParamsHost_MIMEParamsStructure();
}

}
