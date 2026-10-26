#include "JSConnectionsListPrototype.h"
#include "JSConnectionsList.h"
#include "ErrorCode.h"
#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include "uv.h"

namespace Bun {

using namespace JSC;

const ClassInfo JSConnectionsListPrototype::s_info = { "ConnectionsList"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSConnectionsListPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSConnectionsListPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSConnectionsListPrototype

void JSConnectionsListPrototype::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSConnectionsListPrototype_install(vm, info(), *this);
}

static JSConnectionsList* connectionsList(const std::optional<JSC::JSValue>& value)
{
    if (!value)
        return nullptr;
    auto* connections = dynamicDowncast<JSConnectionsList>(*value);
    RELEASE_ASSERT(connections);
    return connections;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_connectionsListAll(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_connectionsListAll_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSConnectionsList* connections = connectionsList(args.bindingThis);
    if (!connections)
        return std::nullopt;

    JSArray* result = connections->all(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    return result;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_connectionsListIdle(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_connectionsListIdle_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSConnectionsList* connections = connectionsList(args.bindingThis);
    if (!connections)
        return std::nullopt;

    JSArray* result = connections->idle(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    return result;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_connectionsListActive(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_connectionsListActive_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSConnectionsList* connections = connectionsList(args.bindingThis);
    if (!connections)
        return std::nullopt;

    JSArray* result = connections->active(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    return result;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_connectionsListExpired(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_connectionsListExpired_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSConnectionsList* connections = connectionsList(args.bindingThis);
    if (!connections)
        return std::nullopt;

    uint64_t headersTimeout = static_cast<uint64_t>(args.headersTimeout) * 1000000;
    uint64_t requestTimeout = static_cast<uint64_t>(args.requestTimeout) * 1000000;

    if (headersTimeout == 0 && requestTimeout == 0) {
        JSArray* result = constructEmptyArray(globalObject, nullptr);
        RETURN_IF_EXCEPTION(scope, {});
        return result;
    } else if (requestTimeout > 0 && headersTimeout > requestTimeout) {
        std::swap(headersTimeout, requestTimeout);
    }

    const uint64_t now = uv_hrtime();

    const uint64_t headersDeadline = (headersTimeout > 0 && now > headersTimeout) ? now - headersTimeout : 0;
    const uint64_t requestDeadline = (requestTimeout > 0 && now > requestTimeout) ? now - requestTimeout : 0;

    if (headersDeadline == 0 && requestDeadline == 0) {
        JSArray* result = constructEmptyArray(globalObject, nullptr);
        RETURN_IF_EXCEPTION(scope, {});
        return result;
    }

    JSArray* result = connections->expired(globalObject, headersDeadline, requestDeadline);
    RETURN_IF_EXCEPTION(scope, {});

    return result;
}

} // namespace Bun
