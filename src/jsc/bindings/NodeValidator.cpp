#include "root.h"

#include "ZigGlobalObject.h"
#include "JavaScriptCore/JSGlobalObject.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "JavaScriptCore/CallData.h"
#include "JavaScriptCore/JSObjectInlines.h"
#include "JavaScriptCore/JSType.h"
#include "JavaScriptCore/TypedArrayType.h"
#include "JavaScriptCore/ArrayConstructor.h"
#include <cmath>
#include <limits>

#include "ErrorCode.h"
#include "NodeValidator.h"

namespace Bun {

using namespace JSC;

template<typename T> JSC::EncodedJSValue V::validateInteger(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSC::JSValue value, JSC::JSValue name, JSC::JSValue min, JSC::JSValue max, T* out)
{
    if (!value.isNumber()) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "number"_s, value);
    if (min.isUndefined()) min = jsDoubleNumber(JSC::minSafeInteger());
    if (max.isUndefined()) max = jsDoubleNumber(JSC::maxSafeInteger());

    auto value_num = value.asNumber();
    auto min_num = min.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto max_num = max.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    max_num = std::max(min_num, max_num);

    if (std::fmod(value_num, 1.0) != 0) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, "an integer"_s, value);
    if (value_num < min_num || value_num > max_num) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min_num, max_num, value);

    *out = value_num;
    return JSValue::encode(jsUndefined());
}
template<typename T> JSC::EncodedJSValue V::validateInteger(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSC::JSValue value, ASCIILiteral name, JSC::JSValue min, JSC::JSValue max, T* out)
{
    if (!value.isNumber()) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "number"_s, value);
    if (min.isUndefined()) min = jsDoubleNumber(JSC::minSafeInteger());
    if (max.isUndefined()) max = jsDoubleNumber(JSC::maxSafeInteger());

    auto value_num = value.asNumber();
    auto min_num = min.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto max_num = max.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    max_num = std::max(min_num, max_num);

    if (std::fmod(value_num, 1.0) != 0) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, "an integer"_s, value);
    if (value_num < min_num || value_num > max_num) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min_num, max_num, value);

    *out = value_num;
    return JSValue::encode(jsUndefined());
}

JSC::EncodedJSValue V::validateNumber(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, JSValue name, JSValue min, JSValue max)
{
    if (!value.isNumber()) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "number"_s, value);

    auto value_num = value.asNumber();
    auto min_num = min.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto max_num = max.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    auto min_isnonnull = !min.isUndefinedOrNull();
    auto max_isnonnull = !max.isUndefinedOrNull();

    if ((min_isnonnull && value_num < min_num) || (max_isnonnull && value_num > max_num) || ((min_isnonnull || max_isnonnull) && std::isnan(value_num))) {
        if (min_isnonnull && max_isnonnull) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min_num, max_num, value);
        if (min_isnonnull) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min_num, Bun::LOWER, value);
        if (max_isnonnull) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, max_num, Bun::UPPER, value);
        return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, ""_s, value);
    }

    return JSValue::encode(jsUndefined());
}
JSC::EncodedJSValue V::validateNumber(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, ASCIILiteral name, JSValue min, JSValue max)
{
    if (!value.isNumber()) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "number"_s, value);

    auto value_num = value.asNumber();
    auto min_num = min.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto max_num = max.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    auto min_isnonnull = !min.isUndefinedOrNull();
    auto max_isnonnull = !max.isUndefinedOrNull();

    if ((min_isnonnull && value_num < min_num) || (max_isnonnull && value_num > max_num) || ((min_isnonnull || max_isnonnull) && std::isnan(value_num))) {
        if (min_isnonnull && max_isnonnull) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min_num, max_num, value);
        if (min_isnonnull) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min_num, Bun::LOWER, value);
        if (max_isnonnull) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, max_num, Bun::UPPER, value);
        return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, ""_s, value);
    }

    return JSValue::encode(jsUndefined());
}

JSC::EncodedJSValue V::validateString(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, ASCIILiteral name)
{
    if (!value.isString()) {
        return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "string"_s, value);
    }
    return JSValue::encode(jsUndefined());
}

JSC::EncodedJSValue V::validateString(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, JSValue name)
{
    if (!value.isString()) {
        return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "string"_s, value);
    }
    return JSValue::encode(jsUndefined());
}

JSC::EncodedJSValue V::validateFiniteNumber(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue number, JSValue name)
{
    if (number.isUndefined()) {
        return JSValue::encode(jsBoolean(false));
    }
    if (number.isNumber() && (!std::isnan(number.asNumber())) && (!std::isinf(number.asNumber()))) {
        return JSValue::encode(jsBoolean(true));
    }
    if (number.isNumber() && std::isnan(number.asNumber())) {
        return JSValue::encode(jsBoolean(false));
    }

    Bun::V::validateNumber(scope, globalObject, number, name, jsUndefined(), jsUndefined());
    RETURN_IF_EXCEPTION(scope, {});

    return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, "a finite number"_s, number);
}

JSC::EncodedJSValue V::validateFunction(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, ASCIILiteral name)
{
    if (!value.isCallable()) {
        return ERR::INVALID_ARG_TYPE(scope, globalObject, name, "function"_s, value);
    }

    return JSValue::encode(jsUndefined());
}

JSC::EncodedJSValue V::validateBoolean(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, ASCIILiteral name)
{
    if (!value.isBoolean()) {
        return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "boolean"_s, value);
    }
    return JSValue::encode(jsUndefined());
}

JSC::EncodedJSValue V::validateArray(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, JSValue name, JSValue minLength)
{
    auto& vm = JSC::getVM(globalObject);

    if (minLength.isUndefined()) minLength = jsNumber(0);

    if (!JSC::isArray(globalObject, value)) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "Array"_s, value);

    auto length = value.get(globalObject, Identifier::fromString(vm, "length"_s));
    RETURN_IF_EXCEPTION(scope, {});
    auto length_num = length.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto minLength_num = minLength.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    if (length_num < minLength_num) {
        return Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, name, value, makeString("must be longer than "_s, minLength_num));
    }
    return JSValue::encode(jsUndefined());
}
JSC::EncodedJSValue V::validateArray(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, ASCIILiteral name, JSValue minLength)
{
    auto& vm = JSC::getVM(globalObject);

    if (minLength.isUndefined()) minLength = jsNumber(0);

    if (!JSC::isArray(globalObject, value)) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "Array"_s, value);

    auto length = value.get(globalObject, Identifier::fromString(vm, "length"_s));
    RETURN_IF_EXCEPTION(scope, {});
    auto length_num = length.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto minLength_num = minLength.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    if (length_num < minLength_num) {
        return Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, name, value, makeString("must be longer than "_s, minLength_num));
    }
    return JSValue::encode(jsUndefined());
}

JSC::EncodedJSValue V::validateArrayBufferView(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value,
    ASCIILiteral name)
{
    if (value.isCell()) {
        auto type = value.asCell()->type();
        if (type >= Int8ArrayType && type <= DataViewType) {
            return JSValue::encode(jsUndefined());
        }
    }

    return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "Buffer, TypedArray, or DataView"_s, value);
}

EncodedJSValue V::validateInt32(ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, JSValue name, JSValue min, JSValue max)
{
    if (value.isInt32() && min.isUndefined() && max.isUndefined()) {
        return JSValue::encode(jsUndefined());
    }

    if (!value.isNumber()) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "number"_s, value);

    if (min.isUndefined()) min = jsNumber(std::numeric_limits<int32_t>().min());
    if (max.isUndefined()) max = jsNumber(std::numeric_limits<int32_t>().max());

    auto value_num = value.asNumber();
    auto min_num = min.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto max_num = max.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    if (std::fmod(value_num, 1.0) != 0) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, "an integer"_s, value);
    if (value_num < min_num || value_num > max_num) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min_num, max_num, value);

    return JSValue::encode(jsUndefined());
}

EncodedJSValue V::validateInt32(ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, ASCIILiteral name, JSValue min, JSValue max, int32_t* out)
{
    if (value.isInt32() && min.isUndefined() && max.isUndefined()) {
        if (out) {
            *out = value.asInt32();
        }
        return JSValue::encode(jsUndefined());
    }

    if (!value.isNumber()) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "number"_s, value);

    if (min.isUndefined()) min = jsNumber(std::numeric_limits<int32_t>().min());
    if (max.isUndefined()) max = jsNumber(std::numeric_limits<int32_t>().max());

    auto value_num = value.asNumber();
    auto min_num = min.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto max_num = max.toNumber(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    if (std::fmod(value_num, 1.0) != 0) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, "an integer"_s, value);
    if (value_num < min_num || value_num > max_num) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min_num, max_num, value);

    if (out) {
        *out = static_cast<int32_t>(std::round(value_num));
    }

    return JSValue::encode(jsUndefined());
}

JSC::EncodedJSValue V::validateUint32(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, JSValue name, JSValue positive, uint32_t* out)
{
    if (!value.isNumber()) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "number"_s, value);
    if (positive.isUndefined()) positive = jsBoolean(false);

    auto value_num = value.asNumber();
    if (std::fmod(value_num, 1.0) != 0) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, "an integer"_s, value);

    auto positive_b = positive.toBoolean(globalObject);
    auto min = positive_b ? 1 : 0;
    auto max = std::numeric_limits<uint32_t>().max();
    if (value_num < min || value_num > max) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min, max, value);

    if (out) {
        *out = static_cast<uint32_t>(std::round(value_num));
    }

    return JSValue::encode(jsUndefined());
}
JSC::EncodedJSValue V::validateUint32(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, ASCIILiteral name, JSValue positive, uint32_t* out)
{
    if (!value.isNumber()) return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "number"_s, value);
    if (positive.isUndefined()) positive = jsBoolean(false);

    auto value_num = value.asNumber();
    if (std::fmod(value_num, 1.0) != 0) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, "an integer"_s, value);

    auto positive_b = positive.toBoolean(globalObject);
    auto min = positive_b ? 1 : 0;
    auto max = std::numeric_limits<uint32_t>().max();
    if (value_num < min || value_num > max) return Bun::ERR::OUT_OF_RANGE(scope, globalObject, name, min, max, value);

    if (out) {
        *out = static_cast<uint32_t>(std::round(value_num));
    }

    return JSValue::encode(jsUndefined());
}

JSC::EncodedJSValue V::validateOneOf(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, ASCIILiteral name, JSValue value, std::span<const ASCIILiteral> oneOf)
{
    if (!value.isString()) {
        return Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, name, "must be one of: "_s, value, oneOf);
    }

    JSC::JSString* valueStr = value.toString(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto valueView = valueStr->view(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    for (ASCIILiteral oneOfStr : oneOf) {

        if (valueView == oneOfStr) {
            return JSValue::encode(jsUndefined());
        }
    }

    return Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, name, "must be one of: "_s, value, oneOf);
}

JSC::EncodedJSValue V::validateOneOf(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, ASCIILiteral name, JSValue value, std::span<const int32_t> oneOf, int32_t* out)
{
    if (!value.isInt32()) {
        return Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, name, "must be one of: "_s, value, oneOf);
    }

    int32_t value_num = value.asInt32();
    for (int32_t oneOfNum : oneOf) {
        if (value_num == oneOfNum) {
            if (out) {
                *out = oneOfNum;
            }
            return JSValue::encode(jsUndefined());
        }
    }

    return Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, name, "must be one of: "_s, value, oneOf);
}

JSC::EncodedJSValue V::validateObject(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSValue value, ASCIILiteral name)
{
    if (value.isNull() || JSC::isArray(globalObject, value) || value.isCallable()) {
        return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "object"_s, value);
    }

    if (!value.isObject()) {
        return Bun::ERR::INVALID_ARG_TYPE(scope, globalObject, name, "object"_s, value);
    }

    return JSValue::encode(jsUndefined());
}

//
//

template JSC::EncodedJSValue V::validateInteger<size_t>(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSC::JSValue value, JSC::JSValue name, JSC::JSValue min, JSC::JSValue max, size_t* out);
template JSC::EncodedJSValue V::validateInteger<ssize_t>(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSC::JSValue value, JSC::JSValue name, JSC::JSValue min, JSC::JSValue max, ssize_t* out);
template JSC::EncodedJSValue V::validateInteger<uint32_t>(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSC::JSValue value, JSC::JSValue name, JSC::JSValue min, JSC::JSValue max, uint32_t* out);
template JSC::EncodedJSValue V::validateInteger<int32_t>(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSC::JSValue value, ASCIILiteral name, JSC::JSValue min, JSC::JSValue max, int32_t* out);
template JSC::EncodedJSValue V::validateInteger<size_t>(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSC::JSValue value, ASCIILiteral name, JSC::JSValue min, JSC::JSValue max, size_t* out);
template JSC::EncodedJSValue V::validateInteger<ssize_t>(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSC::JSValue value, ASCIILiteral name, JSC::JSValue min, JSC::JSValue max, ssize_t* out);
template JSC::EncodedJSValue V::validateInteger<uint32_t>(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, JSC::JSValue value, ASCIILiteral name, JSC::JSValue min, JSC::JSValue max, uint32_t* out);
}
