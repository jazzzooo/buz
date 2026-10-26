#include "root.h"
#include "SchemaBindings.h"
#include "ErrorCode.h"
#include "blob.h"
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferViewInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSONObject.h>
#include <wtf/text/StringView.h>
#include <algorithm>
#include <cmath>
#include <limits>

namespace Bun {
using namespace JSC;
using namespace Bindgen;

namespace {

static std::optional<JSC::JSValue> sqlBindingOwnProperty(
    JSC::JSGlobalObject& global,
    JSC::JSValue row,
    JSC::JSValue property,
    JSC::ThrowScope& scope)
{
    auto* object = row.getObject();
    if (!object)
        return std::nullopt;

    auto key = property.toPropertyKey(&global);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    JSC::PropertySlot slot(object, JSC::PropertySlot::InternalMethodType::GetOwnProperty);
    if (auto index = JSC::parseIndex(key)) {
        if (!object->methodTable()->getOwnPropertySlotByIndex(object, &global, *index, slot)) {
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            return std::nullopt;
        }
        auto value = slot.getValue(&global, *index);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return value;
    }

    if (!object->methodTable()->getOwnPropertySlot(object, &global, key, slot)) {
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return std::nullopt;
    }
    auto value = slot.getValue(&global, key);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return value;
}

static bool sqlBindingIsStringLike(JSC::JSType type)
{
    return type == JSC::StringType || type == JSC::StringObjectType || type == JSC::DerivedStringObjectType;
}

static bool sqlBindingIsTypedArrayOrArrayBuffer(JSC::JSType type)
{
    return type == JSC::ArrayBufferType || JSC::isTypedArrayType(type);
}

static bool sqlBindingIsArrayLike(JSC::JSType type)
{
    return type == JSC::ArrayType || type == JSC::DerivedArrayType || sqlBindingIsTypedArrayOrArrayBuffer(type);
}

static bool sqlBindingIsIndexable(JSC::JSType type)
{
    switch (type) {
    case JSC::ObjectType:
    case JSC::FinalObjectType:
    case JSC::ArrayType:
    case JSC::DerivedArrayType:
    case JSC::ErrorInstanceType:
    case JSC::JSFunctionType:
    case JSC::InternalFunctionType:
    case JSC::ArrayBufferType:
    case JSC::Int8ArrayType:
    case JSC::Uint8ArrayType:
    case JSC::Uint8ClampedArrayType:
    case JSC::Int16ArrayType:
    case JSC::Uint16ArrayType:
    case JSC::Int32ArrayType:
    case JSC::Uint32ArrayType:
    case JSC::Float16ArrayType:
    case JSC::Float32ArrayType:
    case JSC::Float64ArrayType:
    case JSC::BigInt64ArrayType:
    case JSC::BigUint64ArrayType:
        return true;
    default:
        return false;
    }
}

template<typename Integer>
static bool sqlBindingBigIntIsInRange(JSC::JSValue value, Integer min, Integer max)
{
    if (!value.isBigInt())
        return false;
    auto lower = [&] {
        if constexpr (std::is_signed_v<Integer>)
            return JSC::JSBigInt::compare(value, static_cast<int64_t>(min));
        return JSC::JSBigInt::compare(value, static_cast<uint64_t>(min));
    }();
    if (lower == JSC::JSBigInt::ComparisonResult::LessThan)
        return false;
    auto upper = [&] {
        if constexpr (std::is_signed_v<Integer>)
            return JSC::JSBigInt::compare(value, static_cast<int64_t>(max));
        return JSC::JSBigInt::compare(value, static_cast<uint64_t>(max));
    }();
    return upper == JSC::JSBigInt::ComparisonResult::LessThan || upper == JSC::JSBigInt::ComparisonResult::Equal;
}

static SQLMySQLTypeHint inferMySQL(JSGlobalObject& global, JSValue value)
{
    using Return = SQLMySQLTypeHint;
    if (value.isUndefinedOrNull())
        return Return::null_value;

    if (value.isCell()) {
        auto type = value.asCell()->type();
        if (sqlBindingIsStringLike(type))
            return Return::string;
        if (type == JSC::JSDateType)
            return Return::datetime;
        if (sqlBindingIsTypedArrayOrArrayBuffer(type))
            return Return::blob;
        if (type == JSC::HeapBigIntType) {
            if (sqlBindingBigIntIsInRange(value, std::numeric_limits<int64_t>::min(), std::numeric_limits<int64_t>::max()))
                return Return::signed_longlong;
            if (sqlBindingBigIntIsInRange(value, uint64_t { 0 }, std::numeric_limits<uint64_t>::max()))
                return Return::unsigned_longlong;
            auto scope = DECLARE_THROW_SCOPE(global.vm());
            Bun::throwError(&global, scope, Bun::ErrorCode::ERR_OUT_OF_RANGE, "The value is out of range. It must be >= -9223372036854775808 and <= 18446744073709551615."_s);
            return Return::varchar;
        }
        if (type == JSC::NumberObjectType) {
            auto scope = DECLARE_THROW_SCOPE(global.vm());
            Bun::throwError(&global, scope, Bun::ErrorCode::ERR_INVALID_ARG_TYPE, "Cannot bind NumberObject to query parameter. Use a primitive number instead."_s);
            return Return::varchar;
        }
        if (type == JSC::BooleanObjectType) {
            auto scope = DECLARE_THROW_SCOPE(global.vm());
            Bun::throwError(&global, scope, Bun::ErrorCode::ERR_INVALID_ARG_TYPE, "Cannot bind BooleanObject to query parameter. Use a primitive boolean instead."_s);
            return Return::varchar;
        }
        if (!sqlBindingIsIndexable(type)) {
            auto scope = DECLARE_THROW_SCOPE(global.vm());
            Bun::throwError(&global, scope, Bun::ErrorCode::ERR_INVALID_ARG_TYPE, "Cannot bind this type to query parameter"_s);
            return Return::varchar;
        }
        if (JSC::isObjectType(type))
            return Return::json;
    }

    if (value.isAnyInt()) {
        auto integer = value.asAnyInt();
        if (integer >= 0) {
            if (integer <= std::numeric_limits<int32_t>::max())
                return Return::signed_long;
            if (integer <= std::numeric_limits<uint32_t>::max())
                return Return::unsigned_long;
            if (integer >= std::numeric_limits<int64_t>::max())
                return Return::unsigned_longlong;
            return Return::signed_longlong;
        }
        if (integer >= std::numeric_limits<int32_t>::min())
            return Return::signed_long;
        return Return::signed_longlong;
    }
    if (value.isNumber())
        return Return::double_value;
    if (value.isBoolean())
        return Return::boolean;
    return Return::varchar;
}

static SQLPostgresTypeHint inferPostgres(JSGlobalObject& global, JSValue value)
{
    using Return = SQLPostgresTypeHint;
    if (value.isUndefinedOrNull())
        return Return::null_value;

    if (value.isCell()) {
        auto type = value.asCell()->type();
        if (sqlBindingIsStringLike(type))
            return Return::text;
        if (type == JSC::JSDateType)
            return Return::timestamptz;
        if (sqlBindingIsTypedArrayOrArrayBuffer(type))
            return type == JSC::Int32ArrayType ? Return::int4_array : Return::bytea;
        if (type == JSC::HeapBigIntType)
            return Return::int8;
        if (sqlBindingIsArrayLike(type))
            return Return::json;
        if (type == JSC::NumberObjectType) {
            auto scope = DECLARE_THROW_SCOPE(global.vm());
            Bun::throwError(&global, scope, Bun::ErrorCode::ERR_INVALID_ARG_TYPE, "Number object is ambiguous and cannot be used as a PostgreSQL type"_s);
            return Return::numeric;
        }
        if (type == JSC::BooleanObjectType) {
            auto scope = DECLARE_THROW_SCOPE(global.vm());
            Bun::throwError(&global, scope, Bun::ErrorCode::ERR_INVALID_ARG_TYPE, "Boolean object is ambiguous and cannot be used as a PostgreSQL type"_s);
            return Return::numeric;
        }
        if (!sqlBindingIsIndexable(type)) {
            auto scope = DECLARE_THROW_SCOPE(global.vm());
            Bun::throwError(&global, scope, Bun::ErrorCode::ERR_INVALID_ARG_TYPE, "Unknown object is not a valid PostgreSQL type"_s);
            return Return::numeric;
        }
        if (JSC::isObjectType(type))
            return Return::json;
    }

    if (value.isInt32())
        return Return::int4;
    if (value.isAnyInt()) {
        auto integer = value.asAnyInt();
        return integer >= std::numeric_limits<int32_t>::min() && integer <= std::numeric_limits<int32_t>::max()
            ? Return::int4
            : Return::int8;
    }
    if (value.isNumber())
        return Return::float8;
    if (value.isBoolean())
        return Return::boolean;
    return Return::numeric;
}

template<typename Integer>
static Integer sqlBindingInteger(
    JSC::JSGlobalObject& global,
    JSC::ThrowScope& scope,
    JSC::JSValue value,
    WTF::ASCIILiteral name)
{
    if (value.isUndefined())
        return 0;

    if (value.isBigInt()) {
        if (!sqlBindingBigIntIsInRange(value, std::numeric_limits<Integer>::min(), std::numeric_limits<Integer>::max())) {
            Bun::throwError(&global, scope, Bun::ErrorCode::ERR_OUT_OF_RANGE, "The value is outside the requested integer range"_s);
            return 0;
        }
        if constexpr (std::is_signed_v<Integer>)
            return static_cast<Integer>(JSC::JSBigInt::toBigInt64(value));
        else
            return static_cast<Integer>(JSC::JSBigInt::toBigUInt64(value));
    }

    if (!value.isNumber()) {
        Bun::ERR::INVALID_ARG_TYPE(scope, &global, name, "number"_s, value);
        return 0;
    }

    auto number = value.asNumber();
    if (std::isnan(number))
        return 0;
    if (std::floor(number) != number) {
        Bun::ERR::INVALID_ARG_TYPE(scope, &global, name, "integer"_s, value);
        return 0;
    }

    double minimum = static_cast<double>(std::numeric_limits<Integer>::min());
    double maximum = static_cast<double>(std::numeric_limits<Integer>::max());
    minimum = std::max(minimum, JSC::minSafeInteger());
    maximum = std::min(maximum, JSC::maxSafeInteger());
    if (number < minimum || number > maximum) {
        Bun::ERR::OUT_OF_RANGE(scope, &global, name, minimum, maximum, value);
        return 0;
    }
    return static_cast<Integer>(number);
}

template<typename Output, typename Visitor>
static bool visitParameters(JSGlobalObject& global, JSValue valuesValue, std::optional<JSValue> columnsValue, std::optional<size_t> expectedCount, Output& output, Visitor&& visit)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto* values = uncheckedDowncast<JSArray>(valuesValue.asCell());
    auto* columns = columnsValue ? uncheckedDowncast<JSArray>(columnsValue->asCell()) : nullptr;
    const uint32_t rows = values->length();
    const uint32_t width = columns ? columns->length() : 1;
    const uint64_t count = uint64_t { rows } * width;
    if (count > std::numeric_limits<uint16_t>::max()) {
        throwRangeError(&global, scope, "Too many query parameters"_s);
        return false;
    }
    if (expectedCount && count != *expectedCount) {
        throwRangeError(&global, scope, "Wrong number of query parameters"_s);
        return false;
    }
    if (!output.tryReserveInitialCapacity(static_cast<size_t>(count))) {
        throwOutOfMemoryError(&global, scope);
        return false;
    }
    size_t index = 0;
    for (uint32_t rowIndex = 0; rowIndex < rows && width; ++rowIndex) {
        auto row = values->getIndex(&global, rowIndex);
        RETURN_IF_EXCEPTION(scope, false);
        if (columns && !row.isObject()) {
            scope.throwException(&global, createError(&global, makeString("Expected a row to be returned at index "_s, rowIndex)));
            return false;
        }
        for (uint32_t columnIndex = 0; columnIndex < width; ++columnIndex) {
            auto value = row;
            if (columns) {
                auto property = columns->getIndex(&global, columnIndex);
                RETURN_IF_EXCEPTION(scope, false);
                if (property.isUndefined()) {
                    scope.throwException(&global, createError(&global, makeString("Expected a column at index "_s, columnIndex, " in row "_s, rowIndex)));
                    return false;
                }
                auto own = sqlBindingOwnProperty(global, row, property, scope);
                RETURN_IF_EXCEPTION(scope, false);
                if (!own || own->isUndefined()) {
                    scope.throwException(&global, createError(&global, makeString("Expected a value at index "_s, columnIndex, " in row "_s, rowIndex)));
                    return false;
                }
                value = *own;
            }
            bool success = visit(index++, value);
            ensureStillAliveHere(value);
            RETURN_IF_EXCEPTION(scope, false);
            if (!success) {
                throwOutOfMemoryError(&global, scope);
                return false;
            }
        }
        ensureStillAliveHere(row);
    }
    ensureStillAliveHere(valuesValue);
    if (columnsValue)
        ensureStillAliveHere(*columnsValue);
    return true;
}

static bool copyBuffer(JSGlobalObject& global, JSValue value, CppBytes& result)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    if (auto* view = dynamicDowncast<JSArrayBufferView>(value))
        return result.tryCopy({ static_cast<const uint8_t*>(view->vector()), view->byteLength() });
    if (auto* wrapper = dynamicDowncast<JSArrayBuffer>(value)) {
        auto* buffer = wrapper->impl();
        if (buffer)
            return result.tryCopy({ static_cast<const uint8_t*>(buffer->data()), buffer->byteLength() });
    }
    if (auto blob = WebCore::Blob::retain(value)) {
        auto* impl = blob.get();
        if (ZigExports::bunBindgenZig_Blob_blobNeedsToReadFile(impl)) {
            Bun::throwError(&global, scope, ErrorCode::ERR_INVALID_ARG_TYPE, "File blobs are not supported"_s);
            return false;
        }
        auto owner = ZigExports::bunBindgenZig_Blob_blobSharedData(impl);
        RETURN_IF_EXCEPTION(scope, false);
        if (!owner)
            return false;
        ByteOwner data { owner.value() };
        return result.tryCopy(data.bytes());
    }
    Bun::throwError(&global, scope, ErrorCode::ERR_INVALID_ARG_TYPE, "Expected a string, blob, or array buffer"_s);
    return false;
}

static bool materialize(JSGlobalObject& global, JSValue value, SQLParameterKind kind, bool postgres, SQLParameterResult& result)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    if (value.isUndefinedOrNull()) {
        result.set_null_value(SQLParameterNull::null_value);
        return true;
    }
    if (postgres && value.isString())
        kind = SQLParameterKind::text;
    switch (kind) {
    case SQLParameterKind::boolean:
        result.set_boolean(value.toBoolean(&global));
        return true;
    case SQLParameterKind::int16:
        result.set_int16(sqlBindingInteger<int16_t>(global, scope, value, "i16"_s));
        return true;
    case SQLParameterKind::uint16:
        result.set_uint16(sqlBindingInteger<uint16_t>(global, scope, value, "u16"_s));
        return true;
    case SQLParameterKind::int32:
        result.set_int32(postgres ? (value.isBigInt() ? static_cast<int32_t>(value.toBigInt64(&global)) : value.toInt32(&global)) : sqlBindingInteger<int32_t>(global, scope, value, "i32"_s));
        return true;
    case SQLParameterKind::uint32:
        result.set_uint32(sqlBindingInteger<uint32_t>(global, scope, value, "u32"_s));
        return true;
    case SQLParameterKind::int64:
        result.set_int64(sqlBindingInteger<int64_t>(global, scope, value, "i64"_s));
        return true;
    case SQLParameterKind::uint64:
        result.set_uint64(sqlBindingInteger<uint64_t>(global, scope, value, "u64"_s));
        return true;
    case SQLParameterKind::float32:
        result.set_float32(value.toNumber(&global));
        return true;
    case SQLParameterKind::float64:
        result.set_float64(value.toNumber(&global));
        return true;
    case SQLParameterKind::date:
    case SQLParameterKind::time: {
        double milliseconds;
        if (auto* date = dynamicDowncast<DateInstance>(value))
            milliseconds = date->internalNumber();
        else if (value.isNumber())
            milliseconds = value.asNumber();
        else {
            Bun::throwError(&global, scope, ErrorCode::ERR_INVALID_ARG_TYPE, "Expected a date or number"_s);
            return true;
        }
        if (!(postgres && std::isinf(milliseconds)) && (!std::isfinite(milliseconds) || std::abs(milliseconds) > 8.64e15)) {
            throwRangeError(&global, scope, "Invalid date parameter"_s);
            return true;
        }
        if (kind == SQLParameterKind::date)
            result.set_date(milliseconds);
        else
            result.set_time(milliseconds);
        return true;
    }
    case SQLParameterKind::int32_array:
    case SQLParameterKind::bytes: {
        if (kind == SQLParameterKind::bytes && value.isString())
            break;
        CppBytes bytes;
        bool copied = copyBuffer(global, value, bytes);
        RETURN_IF_EXCEPTION(scope, false);
        if (!copied)
            return false;
        if (kind == SQLParameterKind::int32_array) {
            if (!dynamicDowncast<JSInt32Array>(value)) {
                Bun::throwError(&global, scope, ErrorCode::ERR_INVALID_ARG_TYPE, "Expected an Int32Array"_s);
                return true;
            }
            result.set_int32_array(WTF::move(bytes));
        } else
            result.set_bytes(WTF::move(bytes));
        return true;
    }
    case SQLParameterKind::json: {
        auto text = JSONStringify(&global, value, jsUndefined());
        RETURN_IF_EXCEPTION(scope, true);
        CppBytes bytes;
        if (!bytes.tryEncodeUTF8(text))
            return false;
        result.set_text(WTF::move(bytes));
        return true;
    }
    case SQLParameterKind::text:
        break;
    }
    auto text = value.toWTFString(&global);
    RETURN_IF_EXCEPTION(scope, true);
    CppBytes bytes;
    if (!bytes.tryEncodeUTF8(text))
        return false;
    result.set_text(WTF::move(bytes));
    return true;
}

} // namespace

uint64_t Engine::bunBindgenEngine_SQLParameters_count(
    EngineCallContext&,
    const BunBindgenEngine_SQLParameters_count_Arguments& args)
{
    const auto rows = uncheckedDowncast<JSArray>(args.values.asCell())->length();
    const auto width = args.columns ? uncheckedDowncast<JSArray>(args.columns->asCell())->length() : 1;
    return uint64_t { rows } * width;
}

Engine::BunBindgenEngine_SQLParameters_inferMySQL_Return Engine::bunBindgenEngine_SQLParameters_inferMySQL(
    EngineCallContext& context,
    const BunBindgenEngine_SQLParameters_inferMySQL_Arguments& args)
{
    BunBindgenEngine_SQLParameters_inferMySQL_Return result;
    if (!visitParameters(context.globalObject, args.values, args.columns, std::nullopt, result, [&](size_t, JSValue value) {
            return result.tryAppend(inferMySQL(context.globalObject, value));
        }))
        return {};
    return result;
}

Engine::BunBindgenEngine_SQLParameters_materializeMySQL_Return Engine::bunBindgenEngine_SQLParameters_materializeMySQL(
    EngineCallContext& context,
    const BunBindgenEngine_SQLParameters_materializeMySQL_Arguments& args)
{
    BunBindgenEngine_SQLParameters_materializeMySQL_Return result;
    if (!visitParameters(context.globalObject, args.values, args.columns, args.plan.size(), result, [&](size_t index, JSValue value) {
            SQLParameterResult parameter;
            if (!materialize(context.globalObject, value, args.plan[index], false, parameter))
                return false;
            return result.tryAppend(WTF::move(parameter));
        }))
        return {};
    return result;
}

Engine::BunBindgenEngine_SQLParameters_inferPostgres_Return Engine::bunBindgenEngine_SQLParameters_inferPostgres(
    EngineCallContext& context,
    const BunBindgenEngine_SQLParameters_inferPostgres_Arguments& args)
{
    BunBindgenEngine_SQLParameters_inferPostgres_Return result;
    if (!visitParameters(context.globalObject, args.values, args.columns, std::nullopt, result, [&](size_t, JSValue value) {
            return result.tryAppend(inferPostgres(context.globalObject, value));
        }))
        return {};
    return result;
}

Engine::BunBindgenEngine_SQLParameters_materializePostgres_Return Engine::bunBindgenEngine_SQLParameters_materializePostgres(
    EngineCallContext& context,
    const BunBindgenEngine_SQLParameters_materializePostgres_Arguments& args)
{
    BunBindgenEngine_SQLParameters_materializePostgres_Return result;
    if (!visitParameters(context.globalObject, args.values, args.columns, args.plan.size(), result, [&](size_t index, JSValue value) {
            SQLParameterResult parameter;
            if (!materialize(context.globalObject, value, args.plan[index], true, parameter))
                return false;
            return result.tryAppend(WTF::move(parameter));
        }))
        return {};
    return result;
}

} // namespace Bun
