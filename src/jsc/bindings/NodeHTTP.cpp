#include "root.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/GlobalObjectMethodTable.h>
#include "helpers.h"
#include "BunClientData.h"

#include <JavaScriptCore/AggregateError.h>
#include <JavaScriptCore/ErrorInstance.h>
#include <JavaScriptCore/InternalFieldTuple.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSFunction.h>
#include "wtf/URL.h"
#include "JSFetchHeaders.h"
#include "JSBuffer.h"
#include "JSDOMExceptionHandling.h"
#include <bun-uws/src/App.h>
#include "SchemaBindings.h"
#include "ScriptExecutionContext.h"
#include "AsyncContextFrame.h"
#include <JavaScriptCore/LazyPropertyInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include <limits>
#include <type_traits>
#include "JSSocketAddressDTO.h"
#include "node/JSNodeHTTPServerSocket.h"
#include "node/JSNodeHTTPServerSocketPrototype.h"
namespace Bun {

using namespace JSC;
using namespace WebCore;

static RefPtr<FetchHeaders> optionalFetchHeaders(const std::optional<std::optional<RefPtr<FetchHeaders>>>& value)
{
    if (!value || !*value)
        return nullptr;
    return **value;
}

static EncodedJSValue assignHeadersFromFetchHeaders(FetchHeaders& impl, JSObject* prototype, JSObject* objectValue, JSC::InternalFieldTuple* tuple, JSC::JSGlobalObject* globalObject, JSC::VM& vm)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (impl.size() > std::numeric_limits<uint32_t>::max() / 2) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    const auto arrayLength = static_cast<uint32_t>(impl.size() * 2);
    const auto size = static_cast<unsigned>(std::min<size_t>(impl.sizeAfterJoiningSetCookieHeader(), JSFinalObject::maxInlineCapacity));
    JSC::JSArray* array = constructEmptyArray(globalObject, nullptr, arrayLength);
    RETURN_IF_EXCEPTION(scope, {});
    JSC::JSObject* obj = JSC::constructEmptyObject(globalObject, prototype, size);
    RETURN_IF_EXCEPTION(scope, {});

    unsigned arrayI = 0;

    auto& internal = impl.internalHeaders();
    {
        auto& vec = internal.commonHeaders();
        for (const auto& it : vec) {
            const auto& name = it.key;
            const auto& value = it.value;
            const auto impl = WTF::httpHeaderNameStringImpl(name);
            JSString* jsValue = jsString(vm, value);
            obj->putDirect(vm, Identifier::fromString(vm, impl), jsValue, 0);
            RETURN_IF_EXCEPTION(scope, {});
            array->putDirectIndex(globalObject, arrayI++, jsString(vm, impl));
            RETURN_IF_EXCEPTION(scope, {});
            array->putDirectIndex(globalObject, arrayI++, jsValue);
            RETURN_IF_EXCEPTION(scope, {});
        }
    }

    {
        const auto& values = internal.getSetCookieHeaders();

        size_t count = values.size();

        if (count > 0) {
            JSC::JSArray* setCookies = constructEmptyArray(globalObject, nullptr, count);
            RETURN_IF_EXCEPTION(scope, {});
            const auto setCookieHeaderString = WTF::httpHeaderNameStringImpl(HTTPHeaderName::SetCookie);

            JSString* setCookie = jsString(vm, setCookieHeaderString);

            for (size_t i = 0; i < count; ++i) {
                auto* out = jsString(vm, values[i]);
                array->putDirectIndex(globalObject, arrayI++, setCookie);
                RETURN_IF_EXCEPTION(scope, {});
                array->putDirectIndex(globalObject, arrayI++, out);
                RETURN_IF_EXCEPTION(scope, {});
                setCookies->putDirectIndex(globalObject, i, out);
                RETURN_IF_EXCEPTION(scope, {});
            }

            RETURN_IF_EXCEPTION(scope, {});
            obj->putDirect(vm, JSC::Identifier::fromString(vm, setCookieHeaderString), setCookies, 0);
            RETURN_IF_EXCEPTION(scope, {});
        }
    }

    {
        const auto& vec = internal.uncommonHeaders();
        for (const auto& it : vec) {
            const auto& name = it.key;
            const auto& value = it.value;
            auto lowercaseName = FetchHeaders::lowercaseName(name);
            if (lowercaseName.hasException()) {
                WebCore::propagateException(globalObject, scope, lowercaseName.releaseException());
                return {};
            }
            auto* jsValue = jsString(vm, value);
            obj->putDirect(vm, Identifier::fromString(vm, lowercaseName.releaseReturnValue()), jsValue, 0);
            RETURN_IF_EXCEPTION(scope, {});
            array->putDirectIndex(globalObject, arrayI++, jsString(vm, name));
            RETURN_IF_EXCEPTION(scope, {});
            array->putDirectIndex(globalObject, arrayI++, jsValue);
            RETURN_IF_EXCEPTION(scope, {});
        }
    }

    RELEASE_ASSERT(arrayI == arrayLength);
    tuple->putInternalField(vm, 0, obj);
    tuple->putInternalField(vm, 1, array);

    return JSValue::encode(tuple);
}

static void prepareRequestHeaders(uWS::HttpRequest* request, const std::optional<JSC::JSValue>& methodString, Bun::Bindgen::NodeHTTPServerRequestArgumentsResult& result, JSC::JSGlobalObject* globalObject, JSC::VM& vm)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    {
        std::string_view fullURLStdStr = request->getFullUrl();
        String fullURL = String::fromUTF8ReplacingInvalidSequences({ reinterpret_cast<const Latin1Character*>(fullURLStdStr.data()), fullURLStdStr.length() });
        result.url = jsString(vm, WTF::move(fullURL));
        RETURN_IF_EXCEPTION(scope, void());
    }

    // Get the method.
    if (!methodString) [[unlikely]] {
        std::string_view methodView = request->getMethod();
        WTF::String methodString = String::fromUTF8ReplacingInvalidSequences({ reinterpret_cast<const Latin1Character*>(methodView.data()), methodView.length() });
        result.method = jsString(vm, WTF::move(methodString));
        RETURN_IF_EXCEPTION(scope, void());
    } else {
        result.method = *methodString;
    }

    size_t size = 0;
    for (auto it = request->begin(); it != request->end(); ++it) {
        size++;
    }

    JSC::JSObject* headersObject = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), std::min(size, static_cast<size_t>(JSFinalObject::maxInlineCapacity)));
    RETURN_IF_EXCEPTION(scope, void());
    JSC::JSArray* setCookiesHeaderArray = nullptr;
    JSC::JSString* setCookiesHeaderString = nullptr;
    MarkedArgumentBuffer arrayValues;

    result.headers = headersObject;

    for (auto it = request->begin(); it != request->end(); ++it) {
        auto pair = *it;
        StringView nameView = StringView(std::span { reinterpret_cast<const Latin1Character*>(pair.first.data()), pair.first.length() });
        std::span<Latin1Character> data;
        auto value = String::createUninitialized(pair.second.length(), data);
        if (pair.second.length() > 0)
            memcpy(data.data(), pair.second.data(), pair.second.length());

        HTTPHeaderName name;

        JSString* jsValue = jsString(vm, value);
        RETURN_IF_EXCEPTION(scope, void());

        HTTPHeaderIdentifiers& identifiers = WebCore::clientData(vm)->httpHeaderIdentifiers();
        Identifier nameIdentifier;
        JSString* nameString = nullptr;

        const bool knownHeader = WebCore::findHTTPHeaderName(nameView, name);
        if (knownHeader) {
            nameString = identifiers.stringFor(globalObject, name);
            nameIdentifier = identifiers.identifierFor(vm, name);
        } else {
            WTF::String wtfString = nameView.toString();
            nameString = jsString(vm, wtfString);
            nameIdentifier = Identifier::fromString(vm, wtfString.convertToASCIILowercase());
        }
        RETURN_IF_EXCEPTION(scope, void());

        if (knownHeader && name == WebCore::HTTPHeaderName::SetCookie) {
            if (!setCookiesHeaderArray) {
                setCookiesHeaderArray = constructEmptyArray(globalObject, nullptr);
                RETURN_IF_EXCEPTION(scope, );
                setCookiesHeaderString = nameString;
                headersObject->putDirect(vm, nameIdentifier, setCookiesHeaderArray, 0);
                RETURN_IF_EXCEPTION(scope, void());
            }
            arrayValues.append(setCookiesHeaderString);
            arrayValues.append(jsValue);
            setCookiesHeaderArray->push(globalObject, jsValue);
            RETURN_IF_EXCEPTION(scope, void());

        } else {
            headersObject->putDirectMayBeIndex(globalObject, nameIdentifier, jsValue);
            RETURN_IF_EXCEPTION(scope, void());
            arrayValues.append(nameString);
            arrayValues.append(jsValue);
            RETURN_IF_EXCEPTION(scope, void());
        }
    }

    if (arrayValues.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return;
    }
    JSC::JSArray* array;
    {

        ObjectInitializationScope initializationScope(vm);
        if ((array = JSArray::tryCreateUninitializedRestricted(initializationScope, nullptr, globalObject->arrayStructureForIndexingTypeDuringAllocation(ArrayWithContiguous), arrayValues.size()))) [[likely]] {
            EncodedJSValue* data = arrayValues.data();
            for (size_t i = 0, size = arrayValues.size(); i < size; ++i) {
                array->initializeIndex(initializationScope, i, JSValue::decode(data[i]));
            }
        } else {
            RETURN_IF_EXCEPTION(scope, );
            array = constructArray(globalObject, static_cast<ArrayAllocationProfile*>(nullptr), arrayValues);
            RETURN_IF_EXCEPTION(scope, );
        }
    }

    result.raw_headers = array;
}

// This is an 8% speedup.
static EncodedJSValue assignHeadersFromUWebSockets(uWS::HttpRequest* request, JSObject* prototype, JSObject* objectValue, JSC::InternalFieldTuple* tuple, JSC::JSGlobalObject* globalObject, JSC::VM& vm)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto& builtinNames = WebCore::builtinNames(vm);

    {
        std::string_view fullURLStdStr = request->getFullUrl();
        String fullURL = String::fromUTF8ReplacingInvalidSequences({ reinterpret_cast<const Latin1Character*>(fullURLStdStr.data()), fullURLStdStr.length() });
        PutPropertySlot slot(objectValue, false);
        objectValue->put(objectValue, globalObject, builtinNames.urlPublicName(), jsString(vm, WTF::move(fullURL)), slot);
        RETURN_IF_EXCEPTION(scope, {});
    }

    {
        PutPropertySlot slot(objectValue, false);
        std::string_view methodView = request->getMethod();
        WTF::String methodString;
        switch (methodView.length()) {
        case 3: {
            if (methodView == std::string_view("get", 3)) {
                methodString = "GET"_s;
                break;
            }
            if (methodView == std::string_view("put", 3)) {
                methodString = "PUT"_s;
                break;
            }

            break;
        }
        case 4: {
            if (methodView == std::string_view("post", 4)) {
                methodString = "POST"_s;
                break;
            }
            if (methodView == std::string_view("head", 4)) {
                methodString = "HEAD"_s;
                break;
            }

            if (methodView == std::string_view("copy", 4)) {
                methodString = "COPY"_s;
                break;
            }
        }

        case 5: {
            if (methodView == std::string_view("patch", 5)) {
                methodString = "PATCH"_s;
                break;
            }
            if (methodView == std::string_view("merge", 5)) {
                methodString = "MERGE"_s;
                break;
            }
            if (methodView == std::string_view("trace", 5)) {
                methodString = "TRACE"_s;
                break;
            }
            if (methodView == std::string_view("fetch", 5)) {
                methodString = "FETCH"_s;
                break;
            }
            if (methodView == std::string_view("purge", 5)) {
                methodString = "PURGE"_s;
                break;
            }

            break;
        }

        case 6: {
            if (methodView == std::string_view("delete", 6)) {
                methodString = "DELETE"_s;
                break;
            }

            break;
        }

        case 7: {
            if (methodView == std::string_view("connect", 7)) {
                methodString = "CONNECT"_s;
                break;
            }
            if (methodView == std::string_view("options", 7)) {
                methodString = "OPTIONS"_s;
                break;
            }

            break;
        }
        }

        if (methodString.isNull()) {
            methodString = String::fromUTF8ReplacingInvalidSequences({ reinterpret_cast<const Latin1Character*>(methodView.data()), methodView.length() });
        }
        objectValue->put(objectValue, globalObject, builtinNames.methodPublicName(), jsString(vm, methodString), slot);
        RETURN_IF_EXCEPTION(scope, {});
    }

    size_t size = 0;
    for (auto it = request->begin(); it != request->end(); ++it) {
        size++;
    }

    JSC::JSObject* headersObject = JSC::constructEmptyObject(globalObject, prototype, std::min(size, static_cast<size_t>(JSFinalObject::maxInlineCapacity)));
    RETURN_IF_EXCEPTION(scope, {});
    JSC::JSArray* array = constructEmptyArray(globalObject, nullptr, size * 2);
    RETURN_IF_EXCEPTION(scope, {});
    JSC::JSArray* setCookiesHeaderArray = nullptr;
    JSC::JSString* setCookiesHeaderString = nullptr;

    unsigned i = 0;

    for (auto it = request->begin(); it != request->end(); ++it) {
        auto pair = *it;
        StringView nameView = StringView(std::span { reinterpret_cast<const Latin1Character*>(pair.first.data()), pair.first.length() });
        std::span<Latin1Character> data;
        auto value = String::tryCreateUninitialized(pair.second.length(), data);
        if (value.isNull()) [[unlikely]] {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        if (pair.second.length() > 0)
            memcpy(data.data(), pair.second.data(), pair.second.length());

        HTTPHeaderName name;
        WTF::String nameString;
        WTF::String lowercasedNameString;

        if (WebCore::findHTTPHeaderName(nameView, name)) {
            nameString = WTF::httpHeaderNameStringImpl(name);
            lowercasedNameString = nameString;
        } else {
            nameString = nameView.toString();
            lowercasedNameString = nameString.convertToASCIILowercase();
        }

        JSString* jsValue = jsString(vm, value);

        if (name == WebCore::HTTPHeaderName::SetCookie) {
            if (!setCookiesHeaderArray) {
                setCookiesHeaderArray = constructEmptyArray(globalObject, nullptr);
                RETURN_IF_EXCEPTION(scope, {});
                setCookiesHeaderString = jsString(vm, nameString);
                headersObject->putDirect(vm, Identifier::fromString(vm, lowercasedNameString), setCookiesHeaderArray, 0);
                RETURN_IF_EXCEPTION(scope, {});
            }
            array->putDirectIndex(globalObject, i++, setCookiesHeaderString);
            array->putDirectIndex(globalObject, i++, jsValue);
            setCookiesHeaderArray->push(globalObject, jsValue);
            RETURN_IF_EXCEPTION(scope, {});

        } else {
            headersObject->putDirect(vm, Identifier::fromString(vm, lowercasedNameString), jsValue, 0);
            array->putDirectIndex(globalObject, i++, jsString(vm, nameString));
            array->putDirectIndex(globalObject, i++, jsValue);
            RETURN_IF_EXCEPTION(scope, {});
        }
    }

    tuple->putInternalField(vm, 0, headersObject);
    tuple->putInternalField(vm, 1, array);

    return JSValue::encode(tuple);
}

template<bool isSSL>
static void assignOnNodeJSCompat(uWS::TemplatedApp<isSSL>* app)
{
    app->setOnSocketClosed([](void* socketData, int is_ssl, struct us_socket_t* rawSocket) -> void {
        auto* socket = reinterpret_cast<JSNodeHTTPServerSocket*>(socketData);
        ASSERT(rawSocket == socket->socket || socket->socket == nullptr);
        socket->onClose();
    });
    app->setOnSocketDrain([](void* socketData, int is_ssl, struct us_socket_t* rawSocket) -> void {
        auto* socket = reinterpret_cast<JSNodeHTTPServerSocket*>(socketData);
        ASSERT(rawSocket == socket->socket || socket->socket == nullptr);
        socket->onDrain();
    });
    app->setOnSocketData([](void* socketData, int is_ssl, struct us_socket_t* rawSocket, const char* data, int length, bool last) -> void {
        auto* socket = reinterpret_cast<JSNodeHTTPServerSocket*>(socketData);
        ASSERT(rawSocket == socket->socket || socket->socket == nullptr);
        socket->onData(data, length, last);
    });
    app->setOnSocketUpgraded([](void* socketData, int is_ssl, struct us_socket_t* rawSocket) -> void {
        auto* socket = reinterpret_cast<JSNodeHTTPServerSocket*>(socketData);
        // the socket is adopted and might not be the same as the rawSocket
        socket->socket = rawSocket;
        socket->upgraded = true;
    });
}

void Bindgen::Engine::bunBindgenEngine_NodeHTTP_nodeHTTPAssignOnNodeJSCompat(
    const Bindgen::Engine::BunBindgenEngine_NodeHTTP_nodeHTTPAssignOnNodeJSCompat_Arguments& args)
{
    switch (args.kind) {
    case decltype(args.kind)::tcp:
        return assignOnNodeJSCompat<false>(reinterpret_cast<uWS::TemplatedApp<false>*>(args.app));
    case decltype(args.kind)::ssl:
        return assignOnNodeJSCompat<true>(reinterpret_cast<uWS::TemplatedApp<true>*>(args.app));
    case decltype(args.kind)::h3:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

void Bindgen::Engine::bunBindgenEngine_NodeHTTP_nodeHTTPSetUsingCustomExpectHandler(
    const Bindgen::Engine::BunBindgenEngine_NodeHTTP_nodeHTTPSetUsingCustomExpectHandler_Arguments& args)
{
    switch (args.kind) {
    case decltype(args.kind)::tcp:
        reinterpret_cast<uWS::TemplatedApp<false>*>(args.app)->setUsingCustomExpectHandler(args.enabled);
        return;
    case decltype(args.kind)::ssl:
        reinterpret_cast<uWS::TemplatedApp<true>*>(args.app)->setUsingCustomExpectHandler(args.enabled);
        return;
    case decltype(args.kind)::h3:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

template<bool isSSL>
static Bun::Bindgen::NodeHTTPServerRequestArgumentsResult prepareNodeHTTPRequest(
    Zig::GlobalObject* globalObject,
    const std::optional<JSC::JSValue>& methodString,
    uWS::HttpRequest* request,
    uWS::HttpResponse<isSSL>* response,
    JSValue nodeHTTPResponseValue)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    Bun::Bindgen::NodeHTTPServerRequestArgumentsResult result;
    prepareRequestHeaders(request, methodString, result, globalObject, vm);
    RETURN_IF_EXCEPTION(scope, {});

    JSObject* nodeHTTPResponseObject = nodeHTTPResponseValue.getObject();
    RELEASE_ASSERT(nodeHTTPResponseObject);

    auto* currentSocketDataPtr = reinterpret_cast<JSC::JSCell*>(response->getHttpResponseData()->socketData);

    if (currentSocketDataPtr) {
        auto* thisSocket = uncheckedDowncast<JSNodeHTTPServerSocket>(currentSocketDataPtr);
        thisSocket->currentResponseObject.set(vm, thisSocket, nodeHTTPResponseObject);
        result.socket = thisSocket;
        result.new_socket = false;
        if (thisSocket->m_duplex) {
            result.duplex = thisSocket->m_duplex.get();
        }
    } else {
        JSNodeHTTPServerSocket* socket = JSNodeHTTPServerSocket::create(vm, globalObject->m_JSNodeHTTPServerSocketStructure.getInitializedOnMainThread(globalObject), (us_socket_t*)response, isSSL, nodeHTTPResponseObject);
        RETURN_IF_EXCEPTION(scope, {});

        if (socket->socket)
            response->getHttpResponseData()->socketData = socket;

        result.socket = socket;
        result.new_socket = true;
    }
    result.ancient = request->isAncient();

    // Pass pipelined data (head buffer) for Node.js compat (connect/upgrade events)
    if (!request->head.empty()) {
        WTF::Vector<uint8_t> head;
        if (!head.tryAppend(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(request->head.data()), request->head.size()))) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        result.head.emplace(WTF::move(head));
    }
    return result;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_NodeHTTP_nodeHTTPServerCreateResponse(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_NodeHTTP_nodeHTTPServerCreateResponse_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    switch (args.kind) {
    case decltype(args.kind)::tcp:
        return Bindgen::ZigExports::bunBindgenZig_NodeHTTPResponse_createForServer(
            globalObject,
            args.anyServer,
            args.hasBody,
            args.request,
            false,
            args.response,
            args.upgradeContext);
    case decltype(args.kind)::ssl:
        return Bindgen::ZigExports::bunBindgenZig_NodeHTTPResponse_createForServer(
            globalObject,
            args.anyServer,
            args.hasBody,
            args.request,
            true,
            args.response,
            args.upgradeContext);
    case decltype(args.kind)::h3:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

Bindgen::Engine::BunBindgenEngine_NodeHTTP_nodeHTTPServerPrepareRequest_Return Bindgen::Engine::bunBindgenEngine_NodeHTTP_nodeHTTPServerPrepareRequest(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_NodeHTTP_nodeHTTPServerPrepareRequest_Arguments& args)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    switch (args.kind) {
    case decltype(args.kind)::tcp:
        return prepareNodeHTTPRequest<false>(
            globalObject,
            args.methodString,
            args.request,
            reinterpret_cast<uWS::HttpResponse<false>*>(args.response),
            context.classValue(args.nodeResponse));
    case decltype(args.kind)::ssl:
        return prepareNodeHTTPRequest<true>(
            globalObject,
            args.methodString,
            args.request,
            reinterpret_cast<uWS::HttpResponse<true>*>(args.response),
            context.classValue(args.nodeResponse));
    case decltype(args.kind)::h3:
        RELEASE_ASSERT_NOT_REACHED();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_assignHeaders(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_assignHeaders_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (args.request.is_ignored())
        return std::nullopt;

    JSValue requestValue = args.request.object();
    JSObject* objectValue = args.object.getObject();
    auto* tuple = dynamicDowncast<JSC::InternalFieldTuple>(args.tuple);
    RELEASE_ASSERT(tuple);

    JSValue headersValue = JSValue();
    JSValue urlValue = JSValue();
    if (auto* jsRequest = dynamicDowncast<BunBindgen_Request_Request>(requestValue)) {
        if (auto request = Bindgen::ZigExports::bunBindgenZig_Request_requestGetUWSRequest(jsRequest->native())) {
            return JSValue::decode(assignHeadersFromUWebSockets(*request, globalObject->objectPrototype(), objectValue, tuple, globalObject, vm));
        }

        headersValue = jsRequest->raw_slot_headers();
        urlValue = jsRequest->raw_slot_url();
    }

    if (!headersValue) {
        headersValue = requestValue.getObject()->getIfPropertyExists(globalObject, WebCore::builtinNames(vm).headersPublicName());
        RETURN_IF_EXCEPTION(scope, {});
    }

    if (!urlValue) {
        urlValue = requestValue.getObject()->getIfPropertyExists(globalObject, WebCore::builtinNames(vm).urlPublicName());
        RETURN_IF_EXCEPTION(scope, {});
    }

    if (headersValue) {
        if (auto* headers = dynamicDowncast<WebCore::JSFetchHeaders>(headersValue)) {
            auto protectedHeaders = protectedFetchHeaders(globalObject, headers);
            RETURN_IF_EXCEPTION(scope, {});
            RELEASE_ASSERT(protectedHeaders);
            if (urlValue) {
                if (urlValue.isString()) {
                    String url = urlValue.toWTFString(globalObject);
                    RETURN_IF_EXCEPTION(scope, {});
                    if (url.startsWith("https://"_s) || url.startsWith("http://"_s) || url.startsWith("file://"_s)) {
                        WTF::URL urlObj = WTF::URL({}, url);
                        if (urlObj.isValid()) {
                            urlValue = jsString(vm, makeString(urlObj.path(), urlObj.query().isEmpty() ? emptyString() : urlObj.queryWithLeadingQuestionMark()));
                        }
                    }
                } else {
                    urlValue = jsEmptyString(vm);
                }
                PutPropertySlot slot(objectValue, false);
                objectValue->put(objectValue, globalObject, WebCore::builtinNames(vm).urlPublicName(), urlValue, slot);
                RETURN_IF_EXCEPTION(scope, {});
            }

            RELEASE_AND_RETURN(scope, JSValue::decode(assignHeadersFromFetchHeaders(*protectedHeaders, globalObject->objectPrototype(), objectValue, tuple, globalObject, vm)));
        }
    }

    return std::nullopt;
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_setTimeout(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_setTimeout_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (args.request.is_ignored())
        return;

    JSValue request = args.request.object();
    if (auto* jsRequest = dynamicDowncast<BunBindgen_Request_Request>(request)) {
        Bindgen::ZigExports::bunBindgenZig_Request_requestSetTimeout(globalObject, jsRequest->native(), args.seconds);
        RETURN_IF_EXCEPTION(scope, void());
    }

    if (auto* nodeHttpResponse = bun_bindgen_class_NodeHTTPResponse_NodeHTTPResponse_try_cast_value(request)) {
        Bindgen::ZigExports::bunBindgenZig_NodeHTTPResponse_nodeHTTPResponseSetTimeout(globalObject, nodeHttpResponse, args.seconds);
        RETURN_IF_EXCEPTION(scope, void());
    }

    return;
}

std::optional<Bindgen::NodeHTTPHeaderResult> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_getHeader(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_getHeader_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (auto impl = optionalFetchHeaders(args.headers); impl && args.name && args.name->is_string()) {
        const auto& name = args.name->string();
        if (WTF::equalIgnoringASCIICase(name, "set-cookie"_s)) {
            if (!impl->fastHas(HTTPHeaderName::SetCookie))
                return std::nullopt;
            auto cookies = impl->copySetCookieHeaders();
            if (cookies.hasException()) {
                WebCore::propagateException(globalObject, scope, cookies.releaseException());
                return {};
            }
            Bindgen::NodeHTTPHeaderResult result;
            result.set_set_cookie(cookies.releaseReturnValue());
            return result;
        }

        WebCore::ExceptionOr<String> res = impl->get(name);
        if (res.hasException()) {
            WebCore::propagateException(globalObject, scope, res.releaseException());
            RELEASE_AND_RETURN(scope, {});
        }

        String value = res.releaseReturnValue();
        if (value.isNull())
            return std::nullopt;

        Bindgen::NodeHTTPHeaderResult result;
        result.set_value(WTF::move(value));
        return result;
    }

    return std::nullopt;
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_setHeader(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_setHeader_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (auto impl = optionalFetchHeaders(args.headers); impl && args.name && args.name->is_string()) {
        const auto& name = args.name->string();

        if (!args.value || !args.value->has_value())
            return;

        const auto& value = **args.value;
        if (value.is_values()) {
            const auto& values = value.values();
            if (!values.isEmpty()) {
                WebCore::propagateException(*globalObject, scope, impl->set(name, values[0]));
                RETURN_IF_EXCEPTION(scope, void());
            }
            for (size_t i = 1; i < values.size(); ++i) {
                WebCore::propagateException(*globalObject, scope, impl->append(name, values[i]));
                RETURN_IF_EXCEPTION(scope, void());
            }
            return;
        }

        WebCore::propagateException(*globalObject, scope, impl->set(name, value.value()));
        RETURN_IF_EXCEPTION(scope, void());
        return;
    }

    return;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeHTTP_createHeadersTuple(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_createHeadersTuple_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    VM& vm = globalObject->vm();
    return JSC::InternalFieldTuple::create(vm, globalObject->m_internalFieldTupleStructure.get());
}

} // namespace Bun
