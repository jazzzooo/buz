#include "root.h"
#include "SchemaBindings.h"

#include "JavaScriptCore/JSGlobalObject.h"
#include <JavaScriptCore/StructureInlines.h>
#include <JavaScriptCore/ObjectPrototype.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/JSBigInt.h>
#include <JavaScriptCore/DateInstance.h>
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/GCDeferralContext.h>
#include "GCDefferalContext.h"
#include "wtf/Assertions.h"

#include "JavaScriptCore/ArgList.h"
#include "JavaScriptCore/ArrayAllocationProfile.h"
#include "JavaScriptCore/ExceptionScope.h"
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferViewInlines.h>
#include "JavaScriptCore/JSArrayBufferView.h"
#include "JavaScriptCore/JSCast.h"
#include "JavaScriptCore/JSGlobalObjectInlines.h"
#include "JavaScriptCore/JSType.h"
#include "JavaScriptCore/TypedArrayAdaptersForwardDeclarations.h"
#include <span>
#include <wtf/Vector.h>

namespace Bun {
using namespace JSC;
using Bindgen::SQLDataCellNode;
using Bindgen::SQLResultColumnSlot;
using Bindgen::SQLResultLayoutFlags;
using Bindgen::SQLResultMode;
using Bindgen::SQLTypedArrayKind;

// Empty wire spans represent a non-null empty string.
static WTF::String sqlLatin1String(std::span<const uint8_t> units)
{
    return WTF::StringImpl::create(units);
}

static WTF::String sqlUTF16String(std::span<const uint16_t> units)
{
    return WTF::StringImpl::create(WTF::spanReinterpretCast<const char16_t>(units));
}

class SQLDataCellCursor {
public:
    SQLDataCellCursor(JSGlobalObject* global, std::span<const SQLDataCellNode> nodes, ThrowScope& scope)
        : m_global(global)
        , m_vm(getVM(global))
        , m_nodes(nodes)
        , m_scope(scope)
    {
    }

    JSValue materialize()
    {
        const auto& node = take();
        switch (node.tag()) {
        case SQLDataCellNode::Tag::null_value:
            return jsNull();
        case SQLDataCellNode::Tag::string_latin1:
            return jsString(m_vm, sqlLatin1String(node.string_latin1().units));
        case SQLDataCellNode::Tag::string_utf16:
            return jsString(m_vm, sqlUTF16String(node.string_utf16().units));
        case SQLDataCellNode::Tag::double_value:
            return jsNumber(node.double_value());
        case SQLDataCellNode::Tag::int32:
            return jsNumber(node.int32());
        case SQLDataCellNode::Tag::int64:
            RELEASE_AND_RETURN(m_scope, JSBigInt::createFrom(m_global, node.int64()));
        case SQLDataCellNode::Tag::boolean:
            return jsBoolean(node.boolean());
        case SQLDataCellNode::Tag::date:
            return DateInstance::create(m_vm, m_global->dateStructure(), node.date().milliseconds);
        case SQLDataCellNode::Tag::date_with_timezone:
            return DateInstance::create(m_vm, m_global->dateStructure(), node.date_with_timezone().milliseconds);
        case SQLDataCellNode::Tag::bytea:
            return materializeBytes(node.bytea().bytes);
        case SQLDataCellNode::Tag::json_null:
            return jsNull();
        case SQLDataCellNode::Tag::json_latin1: {
            auto result = JSONParseWithException(m_global, sqlLatin1String(node.json_latin1().units));
            RETURN_IF_EXCEPTION(m_scope, {});
            return result;
        }
        case SQLDataCellNode::Tag::json_utf16: {
            auto result = JSONParseWithException(m_global, sqlUTF16String(node.json_utf16().units));
            RETURN_IF_EXCEPTION(m_scope, {});
            return result;
        }
        case SQLDataCellNode::Tag::array:
            return materializeArray(node.array().length);
        case SQLDataCellNode::Tag::typed_array:
            return materializeTypedArray(node.typed_array());
        case SQLDataCellNode::Tag::raw:
            return materializeBytes(node.raw().bytes);
        case SQLDataCellNode::Tag::uint32:
            return jsNumber(node.uint32());
        case SQLDataCellNode::Tag::uint64:
            RELEASE_AND_RETURN(m_scope, JSBigInt::createFrom(m_global, node.uint64()));
        case SQLDataCellNode::Tag::none:
            RELEASE_ASSERT_NOT_REACHED();
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    bool atEnd() const { return m_index == m_nodes.size(); }

    void skip()
    {
        const auto& node = take();
        switch (node.tag()) {
        case SQLDataCellNode::Tag::array: {
            const uint32_t length = node.array().length;
            RELEASE_ASSERT(length <= remaining());
            for (uint32_t index = 0; index < length; ++index)
                skip();
            return;
        }
        case SQLDataCellNode::Tag::null_value:
        case SQLDataCellNode::Tag::string_latin1:
        case SQLDataCellNode::Tag::string_utf16:
        case SQLDataCellNode::Tag::double_value:
        case SQLDataCellNode::Tag::int32:
        case SQLDataCellNode::Tag::int64:
        case SQLDataCellNode::Tag::boolean:
        case SQLDataCellNode::Tag::date:
        case SQLDataCellNode::Tag::date_with_timezone:
        case SQLDataCellNode::Tag::bytea:
        case SQLDataCellNode::Tag::json_null:
        case SQLDataCellNode::Tag::json_latin1:
        case SQLDataCellNode::Tag::json_utf16:
        case SQLDataCellNode::Tag::typed_array:
        case SQLDataCellNode::Tag::raw:
        case SQLDataCellNode::Tag::uint32:
        case SQLDataCellNode::Tag::uint64:
            return;
        case SQLDataCellNode::Tag::none:
            RELEASE_ASSERT_NOT_REACHED();
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

private:
    const SQLDataCellNode& take()
    {
        RELEASE_ASSERT(m_index < m_nodes.size());
        return m_nodes[m_index++];
    }

    size_t remaining() const { return m_nodes.size() - m_index; }

    JSValue materializeBytes(std::span<const uint8_t> bytes)
    {
        auto* zigGlobal = uncheckedDowncast<Zig::GlobalObject>(m_global);
        auto* array = JSUint8Array::createUninitialized(m_global, zigGlobal->JSBufferSubclassStructure(), bytes.size());
        RETURN_IF_EXCEPTION(m_scope, {});
        if (!bytes.empty())
            memcpy(array->vector(), bytes.data(), bytes.size());
        return array;
    }

    JSValue materializeArray(uint32_t length)
    {
        RELEASE_ASSERT(length <= remaining());
        MarkedArgumentBuffer values;
        for (uint32_t index = 0; index < length; ++index) {
            values.append(materialize());
            RETURN_IF_EXCEPTION(m_scope, {});
        }
        RELEASE_AND_RETURN(m_scope, constructArray(m_global, static_cast<ArrayAllocationProfile*>(nullptr), values));
    }

    JSValue materializeTypedArray(const Bindgen::SQLTypedArray& value)
    {
        constexpr size_t elementSize = sizeof(uint32_t);
        static_assert(sizeof(size_t) > sizeof(uint32_t));
        const size_t byteLength = static_cast<size_t>(value.length) * elementSize;
        RELEASE_ASSERT(value.bytes.size() == byteLength);
        switch (value.kind) {
        case SQLTypedArrayKind::int32: {
            auto* array = JSInt32Array::createUninitialized(m_global, m_global->typedArrayStructureWithTypedArrayType<TypedArrayType::TypeInt32>(), value.length);
            RETURN_IF_EXCEPTION(m_scope, {});
            if (value.length)
                memcpy(array->vector(), value.bytes.span().data(), value.bytes.size());
            return array;
        }
        case SQLTypedArrayKind::float32: {
            auto* array = JSFloat32Array::createUninitialized(m_global, m_global->typedArrayStructureWithTypedArrayType<TypedArrayType::TypeFloat32>(), value.length);
            RETURN_IF_EXCEPTION(m_scope, {});
            if (value.length)
                memcpy(array->vector(), value.bytes.span().data(), value.bytes.size());
            return array;
        }
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    JSGlobalObject* m_global;
    VM& m_vm;
    std::span<const SQLDataCellNode> m_nodes;
    ThrowScope& m_scope;
    size_t m_index { 0 };
};

static JSValue materializeResultRow(
    Structure* structure,
    SQLDataCellCursor& cells,
    uint32_t count,
    JSGlobalObject* globalObject,
    const SQLResultLayoutFlags& flags,
    SQLResultMode resultMode,
    std::span<const SQLResultColumnSlot> slots,
    ThrowScope& scope)
{
    auto& vm = getVM(globalObject);
    switch (resultMode) {
    case SQLResultMode::objects: {
        RELEASE_ASSERT(slots.size() == count);
        auto* object = structure ? constructEmptyObject(vm, structure) : constructEmptyObject(globalObject, globalObject->objectPrototype(), 0);

        if (flags.has_named_columns && !flags.has_duplicate_columns && !flags.has_indexed_columns) {
            for (uint32_t index = 0; index < count; ++index) {
                const auto& slot = slots[index];
                auto value = cells.materialize();
                RETURN_IF_EXCEPTION(scope, {});
                if (slot.is_named_latin1()) {
                    object->putDirect(vm, Identifier::fromString(vm, sqlLatin1String(slot.named_latin1())), value);
                } else if (slot.is_named_utf16()) {
                    object->putDirect(vm, Identifier::fromString(vm, sqlUTF16String(slot.named_utf16())), value);
                } else {
                    RELEASE_ASSERT(slot.is_named_offset());
                    object->putDirectOffset(vm, slot.named_offset().value, value);
                }
            }
        } else if (flags.has_indexed_columns && !flags.has_named_columns && !flags.has_duplicate_columns) {
            for (uint32_t index = 0; index < count; ++index) {
                const auto& slot = slots[index];
                auto value = cells.materialize();
                RETURN_IF_EXCEPTION(scope, {});
                RELEASE_ASSERT(slot.is_indexed());
                object->putDirectIndex(globalObject, slot.indexed().value, value);
                RETURN_IF_EXCEPTION(scope, {});
            }
        } else {
            for (uint32_t index = 0; index < count; ++index) {
                const auto& slot = slots[index];
                if (slot.is_indexed()) {
                    auto value = cells.materialize();
                    RETURN_IF_EXCEPTION(scope, {});
                    object->putDirectIndex(globalObject, slot.indexed().value, value);
                    RETURN_IF_EXCEPTION(scope, {});
                } else if (slot.is_named_latin1()) {
                    auto value = cells.materialize();
                    RETURN_IF_EXCEPTION(scope, {});
                    object->putDirect(vm, Identifier::fromString(vm, sqlLatin1String(slot.named_latin1())), value);
                } else if (slot.is_named_utf16()) {
                    auto value = cells.materialize();
                    RETURN_IF_EXCEPTION(scope, {});
                    object->putDirect(vm, Identifier::fromString(vm, sqlUTF16String(slot.named_utf16())), value);
                } else if (slot.is_named_offset()) {
                    auto value = cells.materialize();
                    RETURN_IF_EXCEPTION(scope, {});
                    object->putDirectOffset(vm, slot.named_offset().value, value);
                } else {
                    RELEASE_ASSERT(slot.is_duplicate());
                    cells.skip();
                }
            }
        }
        return object;
    }
    case SQLResultMode::raw:
    case SQLResultMode::values: {
        auto* array = constructEmptyArray(globalObject, static_cast<ArrayAllocationProfile*>(nullptr), count);
        RETURN_IF_EXCEPTION(scope, {});
        for (uint32_t index = 0; index < count; ++index) {
            auto value = cells.materialize();
            RETURN_IF_EXCEPTION(scope, {});
            array->putDirectIndex(globalObject, index, value);
            RETURN_IF_EXCEPTION(scope, {});
        }
        return array;
    }
    }
    RELEASE_ASSERT_NOT_REACHED();
}

uint32_t Bindgen::Engine::bunBindgenEngine_SQLTypes_bindingValuesLength(
    Bindgen::EngineCallContext&,
    const Bindgen::Engine::BunBindgenEngine_SQLTypes_bindingValuesLength_Arguments& args)
{
    auto* values = dynamicDowncast<JSArray>(args.values);
    RELEASE_ASSERT(values);
    return values->length();
}

void Bindgen::Engine::bunBindgenEngine_SQLTypes_appendResultRow(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_SQLTypes_appendResultRow_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* rows = dynamicDowncast<JSArray>(args.rows);
    auto* structure = args.structure ? dynamicDowncast<Structure>(args.structure.value()) : nullptr;
    RELEASE_ASSERT(rows);
    RELEASE_ASSERT(!args.structure || structure);

    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    SQLDataCellCursor cells(globalObject, args.nodes, scope);
    JSValue row = materializeResultRow(structure, cells, args.count, globalObject, args.flags, args.resultMode, args.slots, scope);
    RETURN_IF_EXCEPTION(scope, );
    RELEASE_ASSERT(cells.atEnd());
    rows->push(globalObject, row);
    RETURN_IF_EXCEPTION(scope, );
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_SQLTypes_createResultRows(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_SQLTypes_createResultRows_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* structure = args.structure ? dynamicDowncast<Structure>(args.structure.value()) : nullptr;
    RELEASE_ASSERT(!args.structure || structure);

    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    SQLDataCellCursor cells(globalObject, args.nodes, scope);
    JSValue row = materializeResultRow(structure, cells, args.count, globalObject, args.flags, args.resultMode, args.slots, scope);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(cells.atEnd());

    auto* rows = JSC::constructEmptyArray(globalObject, static_cast<ArrayAllocationProfile*>(nullptr), 1);
    RETURN_IF_EXCEPTION(scope, {});
    rows->putDirectIndex(globalObject, 0, row);
    RETURN_IF_EXCEPTION(scope, {});
    return rows;
}

std::optional<JSC::JSValue> Bindgen::Engine::bunBindgenEngine_SQLTypes_createObjectStructure(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_SQLTypes_createObjectStructure_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);

    PropertyNameArrayBuilder propertyNames(vm, PropertyNameMode::Strings, PrivateSymbolMode::Exclude);
    for (const auto& slot : args.slots) {
        if (slot.is_named_latin1()) {
            propertyNames.add(Identifier::fromString(vm, sqlLatin1String(slot.named_latin1())));
        } else if (slot.is_named_utf16()) {
            propertyNames.add(Identifier::fromString(vm, sqlUTF16String(slot.named_utf16())));
        }
    }

    if (propertyNames.size() > JSFinalObject::maxInlineCapacity)
        return std::nullopt;

    Structure* structure = globalObject->structureCache().emptyObjectStructureForPrototype(globalObject, globalObject->objectPrototype(), propertyNames.size());
    vm.writeBarrier(structure);
    ensureStillAliveHere(structure);

    if (propertyNames.size() > 0) {
        PropertyOffset offset = 0;
        uint32_t indexInPropertyNamesArray = 0;
        uint32_t propertyNamesSize = propertyNames.size();
        for (const auto& slot : args.slots) {
            if (slot.is_named_latin1() || slot.is_named_utf16()) {
                structure = structure->addPropertyTransition(vm, structure, propertyNames[indexInPropertyNamesArray++], 0, offset);
                if (indexInPropertyNamesArray == propertyNamesSize)
                    break;
            }
        }
    }

    return structure;
}

static size_t formatPostgresTime(int64_t microseconds, char* buffer, size_t bufferSize)
{
    // Convert microseconds since midnight to time components
    int64_t totalSeconds = microseconds / 1000000;

    int hours = static_cast<int>(totalSeconds / 3600);
    int minutes = static_cast<int>((totalSeconds % 3600) / 60);
    int seconds = static_cast<int>(totalSeconds % 60);

    // Format following SQL standard time format
    int charactersWritten = snprintf(buffer, bufferSize, "%02d:%02d:%02d", hours, minutes, seconds);

    // Add fractional seconds if present (PostgreSQL supports microsecond precision)
    if (microseconds % 1000000 != 0) {
        // PostgreSQL displays fractional seconds only when non-zero
        int us = microseconds % 1000000;
        charactersWritten = snprintf(buffer, bufferSize, "%02d:%02d:%02d.%06d",
            hours, minutes, seconds, us);
        // Trim trailing zeros for cleaner output
        while (buffer[charactersWritten - 1] == '0')
            charactersWritten--;
        if (buffer[charactersWritten - 1] == '.')
            charactersWritten--;
        buffer[charactersWritten] = '\0';
    }

    ASSERT(charactersWritten > 0 && static_cast<unsigned>(charactersWritten) < bufferSize);
    return charactersWritten;
}

static size_t formatPostgresTimeTz(int64_t microseconds, int32_t tzOffsetSeconds, char* buffer, size_t bufferSize)
{
    // Format time part first
    size_t timeLen = formatPostgresTime(microseconds, buffer, bufferSize);

    // PostgreSQL convention: negative offset means positive UTC offset
    // Add timezone in ±HH or ±HH:MM format
    int tzHours = abs(tzOffsetSeconds) / 3600;
    int tzMinutes = (abs(tzOffsetSeconds) % 3600) / 60;

    int tzLen = snprintf(buffer + timeLen, bufferSize - timeLen, "%c%02d",
        tzOffsetSeconds <= 0 ? '+' : '-', tzHours);

    if (tzMinutes != 0) {
        tzLen = snprintf(buffer + timeLen, bufferSize - timeLen, "%c%02d:%02d",
            tzOffsetSeconds <= 0 ? '+' : '-', tzHours, tzMinutes);
    }

    return timeLen + tzLen;
}

size_t Bindgen::Engine::bunBindgenEngine_date_time_postgresFormatTime(
    const Bindgen::Engine::BunBindgenEngine_date_time_postgresFormatTime_Arguments& args)
{
    RELEASE_ASSERT(!args.output.empty());
    return formatPostgresTime(args.microseconds, reinterpret_cast<char*>(args.output.data()), args.output.size());
}

size_t Bindgen::Engine::bunBindgenEngine_date_time_postgresFormatTimeTz(
    const Bindgen::Engine::BunBindgenEngine_date_time_postgresFormatTimeTz_Arguments& args)
{
    RELEASE_ASSERT(!args.output.empty());
    return formatPostgresTimeTz(args.microseconds, args.tzOffsetSeconds, reinterpret_cast<char*>(args.output.data()), args.output.size());
}
}
