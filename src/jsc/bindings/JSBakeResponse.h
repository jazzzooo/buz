#pragma once

#include "JSCookieMap.h"
#include "root.h"
#include "SchemaBindings.h"
#include "WebCoreJSBuiltins.h"

namespace Bun {
using namespace JSC;
using namespace WebCore;

enum JSBakeResponseKind : uint8_t {
    Regular = 0,
    Redirect = 1,
    Render = 2,
};

class JSBakeResponse : public BunBindgen_Response_Response {
public:
    using Base = BunBindgen_Response_Response;

    DECLARE_VISIT_CHILDREN;
    DECLARE_INFO;
    static void destroy(JSC::JSCell*);

    static JSBakeResponse* create(JSC::VM& vm, Zig::GlobalObject* globalObject, JSC::Structure* structure);
    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype);

    JSBakeResponseKind kind() const { return m_kind; }
    void kind(JSBakeResponseKind kind) { m_kind = kind; }

    template<typename, JSC::SubspaceAccess mode>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if (mode == JSC::SubspaceAccess::Concurrently) {
            return nullptr;
        }

        return subspaceForImpl(vm);
    }

    static JSC::GCClient::IsoSubspace* subspaceForImpl(JSC::VM& vm);

    void setToThrow(JSC::JSGlobalObject* globalObject, JSC::VM& vm)
    {
        auto scope = DECLARE_THROW_SCOPE(vm);

        JSC::JSFunction* wrapComponentFn = JSC::JSFunction::create(vm, globalObject, bakeSSRResponseWrapComponentCodeGenerator(vm), globalObject);
        RETURN_IF_EXCEPTION(scope, void());

        JSC::MarkedArgumentBuffer args;
        // component
        args.append(jsUndefined());
        // responseObject
        args.append(this);
        // responseOptions
        args.append(jsUndefined());
        // kind
        args.append(JSC::jsNumber(static_cast<unsigned char>(this->kind())));

        auto callData = JSC::getCallData(wrapComponentFn);
        JSC::JSValue wrappedComponent = JSC::call(globalObject, wrapComponentFn, callData, JSC::jsUndefined(), args);
        RETURN_IF_EXCEPTION(scope, );

        this->putDirect(vm, WebCore::builtinNames(vm).typePublicName(), wrappedComponent, 0);
    }

    void wrapInnerComponent(JSC::JSGlobalObject* globalObject, JSC::VM& vm, JSValue component, const std::optional<Bindgen::CppAny>& responseOptions)
    {
        auto scope = DECLARE_THROW_SCOPE(vm);

        this->kind(JSBakeResponseKind::Regular);
        JSC::JSFunction* wrapComponentFn = JSC::JSFunction::create(vm, globalObject, bakeSSRResponseWrapComponentCodeGenerator(vm), globalObject);
        RETURN_IF_EXCEPTION(scope, void());

        JSC::MarkedArgumentBuffer args;
        // component
        args.append(component);
        // responseObject
        args.append(this);
        // responseOptions
        if (responseOptions)
            responseOptions->appendTo(args);
        else
            args.append(jsUndefined());
        // kind
        args.append(JSC::jsNumber(static_cast<unsigned char>(JSBakeResponseKind::Regular)));

        auto callData = JSC::getCallData(wrapComponentFn);
        JSC::JSValue wrappedComponent = JSC::call(globalObject, wrapComponentFn, callData, JSC::jsUndefined(), args);
        RETURN_IF_EXCEPTION(scope, );

        this->putDirect(vm, WebCore::builtinNames(vm).typePublicName(), wrappedComponent, 0);
    }

private:
    JSBakeResponse(JSC::VM& vm, JSC::Structure* structure);
    void finishCreation(JSC::VM& vm);

    JSBakeResponseKind m_kind { JSBakeResponseKind::Regular };
};

void setupJSBakeResponseClassStructure(JSC::LazyClassStructure::Initializer& init);

} // namespace Bun
