#include "ErrorCode.h"
#include "JSBuffer.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"

#include <JavaScriptCore/ArrayConstructor.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <limits>

namespace Bun::Valkey {

using namespace JSC;
using namespace WTF::StringLiterals;
using Bun::Bindgen::RedisErrorKind;
using Bun::Bindgen::RedisResponseCollectionKind;
using Bun::Bindgen::RedisResponseNode;
using Bun::Bindgen::RedisResponseTextKind;

struct ErrorDescriptor {
    ASCIILiteral name;
    ASCIILiteral code;
};

static ErrorDescriptor errorDescriptor(RedisErrorKind kind)
{
    switch (kind) {
    case RedisErrorKind::authentication_failed:
        return { "RedisError"_s, "ERR_REDIS_AUTHENTICATION_FAILED"_s };
    case RedisErrorKind::connection_closed:
        return { "RedisError"_s, "ERR_REDIS_CONNECTION_CLOSED"_s };
    case RedisErrorKind::connection_timeout:
        return { "RedisError"_s, "ERR_REDIS_CONNECTION_TIMEOUT"_s };
    case RedisErrorKind::idle_timeout:
        return { "RedisError"_s, "ERR_REDIS_IDLE_TIMEOUT"_s };
    case RedisErrorKind::invalid_argument:
        return { "RedisError"_s, "ERR_REDIS_INVALID_ARGUMENT"_s };
    case RedisErrorKind::invalid_array:
        return { "RedisError"_s, "ERR_REDIS_INVALID_ARRAY"_s };
    case RedisErrorKind::invalid_bulk_string:
        return { "RedisError"_s, "ERR_REDIS_INVALID_BULK_STRING"_s };
    case RedisErrorKind::invalid_command:
        return { "RedisError"_s, "ERR_REDIS_INVALID_COMMAND"_s };
    case RedisErrorKind::invalid_error_string:
        return { "RedisError"_s, "ERR_REDIS_INVALID_ERROR_STRING"_s };
    case RedisErrorKind::invalid_integer:
        return { "RedisError"_s, "ERR_REDIS_INVALID_INTEGER"_s };
    case RedisErrorKind::invalid_response:
        return { "RedisError"_s, "ERR_REDIS_INVALID_RESPONSE"_s };
    case RedisErrorKind::invalid_response_type:
        return { "RedisError"_s, "ERR_REDIS_INVALID_RESPONSE_TYPE"_s };
    case RedisErrorKind::invalid_simple_string:
        return { "RedisError"_s, "ERR_REDIS_INVALID_SIMPLE_STRING"_s };
    case RedisErrorKind::socket_closed_before_connection:
        return { "Error"_s, "ERR_SOCKET_CLOSED_BEFORE_CONNECTION"_s };
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static JSObject* createValkeyError(JSGlobalObject* global, RedisErrorKind kind, const String& message)
{
    const auto descriptor = errorDescriptor(kind);
    return Bun::createErrorWithCode(global, ErrorType::Error, descriptor.name, descriptor.code, message);
}

static String responseString(std::span<const uint8_t> bytes)
{
    return String::fromUTF8ReplacingInvalidSequences(bytes);
}

static bool parseInt64(std::span<const uint8_t> bytes, int64_t& result)
{
    if (bytes.empty())
        return false;

    size_t index = 0;
    bool negative = false;
    if (bytes[index] == '-' || bytes[index] == '+') {
        negative = bytes[index] == '-';
        if (++index == bytes.size())
            return false;
    }

    constexpr uint64_t negativeLimit = static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) + 1;
    const uint64_t limit = negative ? negativeLimit : static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
    uint64_t magnitude = 0;
    for (; index < bytes.size(); ++index) {
        const uint8_t byte = bytes[index];
        if (byte < '0' || byte > '9')
            return false;
        const uint64_t digit = byte - '0';
        if (magnitude > (limit - digit) / 10)
            return false;
        magnitude = magnitude * 10 + digit;
    }

    if (!negative) {
        result = static_cast<int64_t>(magnitude);
    } else if (magnitude == negativeLimit) {
        result = std::numeric_limits<int64_t>::min();
    } else {
        result = -static_cast<int64_t>(magnitude);
    }
    return true;
}

class ResponseCursor {
public:
    ResponseCursor(JSGlobalObject* global, std::span<const RedisResponseNode> nodes, ThrowScope& scope)
        : m_global(global)
        , m_vm(getVM(global))
        , m_nodes(nodes)
        , m_scope(scope)
    {
    }

    JSValue materialize(bool returnAsBuffer)
    {
        const auto& node = take();
        switch (node.tag()) {
        case RedisResponseNode::Tag::text: {
            const auto& text = node.text();
            switch (text.kind) {
            case RedisResponseTextKind::simple_string:
            case RedisResponseTextKind::verbatim_string:
                return materializeBytes(text.bytes, returnAsBuffer);
            case RedisResponseTextKind::error:
            case RedisResponseTextKind::blob_error:
                return createValkeyError(m_global, RedisErrorKind::invalid_response, responseString(text.bytes));
            case RedisResponseTextKind::big_number: {
                int64_t integer;
                if (parseInt64(text.bytes, integer))
                    return jsNumber(integer);
                return jsString(m_vm, responseString(text.bytes));
            }
                RELEASE_ASSERT_NOT_REACHED();
            }
        }
        case RedisResponseNode::Tag::integer:
            return jsNumber(node.integer());
        case RedisResponseNode::Tag::double_value:
            return jsNumber(node.double_value());
        case RedisResponseNode::Tag::boolean_value:
            return jsBoolean(node.boolean_value());
        case RedisResponseNode::Tag::bulk_string: {
            const auto& bytes = node.bulk_string().bytes;
            return bytes ? materializeBytes(*bytes, returnAsBuffer) : jsNull();
        }
        case RedisResponseNode::Tag::collection:
            return materializeCollection(node.collection().kind, node.collection().length, returnAsBuffer);
        case RedisResponseNode::Tag::map:
            return materializeMap(node.map().length, returnAsBuffer);
        case RedisResponseNode::Tag::attribute:
            return materializeAttribute(node.attribute().length, returnAsBuffer);
        case RedisResponseNode::Tag::push:
            return materializePush(node.push().kind, node.push().length, returnAsBuffer);
        case RedisResponseNode::Tag::null_value:
            return jsNull();
        case RedisResponseNode::Tag::none:
            RELEASE_ASSERT_NOT_REACHED();
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    bool atEnd() const { return m_index == m_nodes.size(); }

private:
    const RedisResponseNode& take()
    {
        RELEASE_ASSERT(m_index < m_nodes.size());
        return m_nodes[m_index++];
    }

    size_t remaining() const { return m_nodes.size() - m_index; }

    JSValue materializeBytes(std::span<const uint8_t> bytes, bool returnAsBuffer)
    {
        if (returnAsBuffer) {
            auto* buffer = WebCore::createBuffer(m_global, bytes);
            RETURN_IF_EXCEPTION(m_scope, {});
            return buffer;
        }
        auto result = jsString(m_vm, responseString(bytes));
        RETURN_IF_EXCEPTION(m_scope, {});
        return result;
    }

    JSValue materializeCollection(RedisResponseCollectionKind kind, uint64_t length, bool returnAsBuffer)
    {
        RELEASE_ASSERT(length <= remaining());
        if (length > std::numeric_limits<unsigned>::max()) {
            throwOutOfMemoryError(m_global, m_scope);
            return {};
        }
        auto* array = constructEmptyArray(m_global, nullptr, static_cast<unsigned>(length));
        RETURN_IF_EXCEPTION(m_scope, {});
        for (unsigned index = 0; index < length; ++index) {
            auto value = materialize(returnAsBuffer);
            RETURN_IF_EXCEPTION(m_scope, {});
            array->putDirectIndex(m_global, index, value);
            RETURN_IF_EXCEPTION(m_scope, {});
        }
        switch (kind) {
        case RedisResponseCollectionKind::array:
        case RedisResponseCollectionKind::set:
            return array;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    JSValue materializeMap(uint64_t length, bool returnAsBuffer)
    {
        RELEASE_ASSERT(length <= remaining() / 2);
        auto* object = constructEmptyObject(m_vm, m_global->nullPrototypeObjectStructure());
        RETURN_IF_EXCEPTION(m_scope, {});
        for (size_t index = 0; index < length; ++index) {
            auto key = materialize(false);
            RETURN_IF_EXCEPTION(m_scope, {});
            auto property = Identifier::fromString(m_vm, key.toWTFString(m_global));
            RETURN_IF_EXCEPTION(m_scope, {});
            auto value = materialize(returnAsBuffer);
            RETURN_IF_EXCEPTION(m_scope, {});
            object->putDirectMayBeIndex(m_global, PropertyName(property), value);
            RETURN_IF_EXCEPTION(m_scope, {});
        }
        return object;
    }

    JSValue materializeAttribute(uint64_t length, bool returnAsBuffer)
    {
        RELEASE_ASSERT(remaining() > 0);
        RELEASE_ASSERT(length <= (remaining() - 1) / 2);
        for (size_t index = 0; index < length; ++index) {
            skip();
            skip();
        }
        return materialize(returnAsBuffer);
    }

    JSValue materializePush(std::span<const uint8_t> kind, uint64_t length, bool returnAsBuffer)
    {
        RELEASE_ASSERT(length <= remaining());
        if (length > std::numeric_limits<unsigned>::max()) {
            throwOutOfMemoryError(m_global, m_scope);
            return {};
        }
        auto* object = constructEmptyObject(m_vm, m_global->nullPrototypeObjectStructure());
        RETURN_IF_EXCEPTION(m_scope, {});
        auto type = materializeBytes(kind, false);
        RETURN_IF_EXCEPTION(m_scope, {});
        auto* data = constructEmptyArray(m_global, nullptr, static_cast<unsigned>(length));
        RETURN_IF_EXCEPTION(m_scope, {});
        for (unsigned index = 0; index < length; ++index) {
            auto value = materialize(returnAsBuffer);
            RETURN_IF_EXCEPTION(m_scope, {});
            data->putDirectIndex(m_global, index, value);
            RETURN_IF_EXCEPTION(m_scope, {});
        }
        object->putDirect(m_vm, Identifier::fromString(m_vm, "type"_s), type);
        RETURN_IF_EXCEPTION(m_scope, {});
        object->putDirect(m_vm, Identifier::fromString(m_vm, "data"_s), data);
        RETURN_IF_EXCEPTION(m_scope, {});
        return object;
    }

    void skip()
    {
        const auto& node = take();
        switch (node.tag()) {
        case RedisResponseNode::Tag::collection: {
            const uint64_t length = node.collection().length;
            RELEASE_ASSERT(length <= remaining());
            for (size_t index = 0; index < length; ++index)
                skip();
            return;
        }
        case RedisResponseNode::Tag::map: {
            const uint64_t length = node.map().length;
            RELEASE_ASSERT(length <= remaining() / 2);
            for (size_t index = 0; index < length; ++index) {
                skip();
                skip();
            }
            return;
        }
        case RedisResponseNode::Tag::attribute: {
            const uint64_t length = node.attribute().length;
            RELEASE_ASSERT(remaining() > 0);
            RELEASE_ASSERT(length <= (remaining() - 1) / 2);
            for (size_t index = 0; index < length; ++index) {
                skip();
                skip();
            }
            skip();
            return;
        }
        case RedisResponseNode::Tag::push: {
            const uint64_t length = node.push().length;
            RELEASE_ASSERT(length <= remaining());
            for (size_t index = 0; index < length; ++index)
                skip();
            return;
        }
        case RedisResponseNode::Tag::text:
        case RedisResponseNode::Tag::integer:
        case RedisResponseNode::Tag::double_value:
        case RedisResponseNode::Tag::boolean_value:
        case RedisResponseNode::Tag::bulk_string:
        case RedisResponseNode::Tag::null_value:
            return;
        case RedisResponseNode::Tag::none:
            RELEASE_ASSERT_NOT_REACHED();
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    JSGlobalObject* m_global;
    VM& m_vm;
    std::span<const RedisResponseNode> m_nodes;
    ThrowScope& m_scope;
    size_t m_index { 0 };
};

} // namespace Bun::Valkey

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_RedisClient_materializeResponse(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_RedisClient_materializeResponse_Arguments& args)
{
    auto* global = &context.globalObject;
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);
    RELEASE_ASSERT(!args.nodes.empty());
    Bun::Valkey::ResponseCursor cursor(global, args.nodes, scope);
    auto result = cursor.materialize(args.returnAsBuffer);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(cursor.atEnd());
    return result;
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_RedisClient_createError(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_RedisClient_createError_Arguments& args)
{
    return Bun::Valkey::createValkeyError(
        &context.globalObject,
        args.kind,
        Bun::Valkey::responseString(args.message));
}
