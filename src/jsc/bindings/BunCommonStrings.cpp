#include "root.h"
#include "BunBuiltinNames.h"
#include "BunCommonStrings.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/LazyProperty.h>
#include <JavaScriptCore/LazyPropertyInlines.h>
#include "ZigGlobalObject.h"
#include <JavaScriptCore/SlotVisitorInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>

namespace Bun {
using namespace JSC;

#define BUN_COMMON_STRINGS_LAZY_PROPERTY_DEFINITION(jsName)                        \
    this->m_commonString_##jsName.initLater(                                       \
        [](const JSC::LazyProperty<JSGlobalObject, JSString>::Initializer& init) { \
            auto& names = WebCore::builtinNames(init.vm);                          \
            auto name = names.jsName##PublicName();                                \
            init.set(jsOwnedString(init.vm, name.string()));                       \
        });

#define BUN_COMMON_STRINGS_LAZY_PROPERTY_DEFINITION_NOT_BUILTIN_NAMES(methodName, stringLiteral) \
    this->m_commonString_##methodName.initLater(                                                 \
        [](const JSC::LazyProperty<JSGlobalObject, JSString>::Initializer& init) {               \
            init.set(jsString(init.vm, AtomString(stringLiteral##_s)));                          \
        });

#define BUN_COMMON_STRINGS_LAZY_PROPERTY_VISITOR(name) this->m_commonString_##name.visit(visitor);
#define BUN_COMMON_STRINGS_LAZY_PROPERTY_VISITOR_NOT_BUILTIN_NAMES(name, literal) this->m_commonString_##name.visit(visitor);

void CommonStrings::initialize()
{
    BUN_COMMON_STRINGS_EACH_NAME(BUN_COMMON_STRINGS_LAZY_PROPERTY_DEFINITION)
    BUN_COMMON_STRINGS_EACH_NAME_NOT_BUILTIN_NAMES(BUN_COMMON_STRINGS_LAZY_PROPERTY_DEFINITION_NOT_BUILTIN_NAMES)
}

template<typename Visitor>
void CommonStrings::visit(Visitor& visitor)
{
    BUN_COMMON_STRINGS_EACH_NAME(BUN_COMMON_STRINGS_LAZY_PROPERTY_VISITOR)
    BUN_COMMON_STRINGS_EACH_NAME_NOT_BUILTIN_NAMES(BUN_COMMON_STRINGS_LAZY_PROPERTY_VISITOR_NOT_BUILTIN_NAMES)
}

template void CommonStrings::visit(JSC::AbstractSlotVisitor&);
template void CommonStrings::visit(JSC::SlotVisitor&);

static JSC::JSValue toJS(Zig::GlobalObject* globalObject, Bindgen::HTTPMethodKind method)
{
#define FOR_EACH_METHOD(method)             \
    case Bindgen::HTTPMethodKind::method:   \
        return globalObject->commonStrings().http##method##String(globalObject);

    switch (method) {
        FOR_EACH_METHOD(ACL)
        FOR_EACH_METHOD(BIND)
        FOR_EACH_METHOD(CHECKOUT)
        FOR_EACH_METHOD(CONNECT)
        FOR_EACH_METHOD(COPY)
    case Bindgen::HTTPMethodKind::DELETE_METHOD:
        return globalObject->commonStrings().httpDELETEString(globalObject);
        FOR_EACH_METHOD(GET)
        FOR_EACH_METHOD(HEAD)
        FOR_EACH_METHOD(LINK)
        FOR_EACH_METHOD(LOCK)
    case Bindgen::HTTPMethodKind::M_SEARCH:
        return globalObject->commonStrings().httpMSEARCHString(globalObject);
        FOR_EACH_METHOD(MERGE)
        FOR_EACH_METHOD(MKACTIVITY)
        FOR_EACH_METHOD(MKADDRESSBOOK)
        FOR_EACH_METHOD(MKCALENDAR)
        FOR_EACH_METHOD(MKCOL)
        FOR_EACH_METHOD(MOVE)
        FOR_EACH_METHOD(NOTIFY)
        FOR_EACH_METHOD(OPTIONS)
        FOR_EACH_METHOD(PATCH)
        FOR_EACH_METHOD(POST)
        FOR_EACH_METHOD(PROPFIND)
        FOR_EACH_METHOD(PROPPATCH)
        FOR_EACH_METHOD(PURGE)
        FOR_EACH_METHOD(PUT)
        FOR_EACH_METHOD(QUERY)
        FOR_EACH_METHOD(REBIND)
        FOR_EACH_METHOD(REPORT)
        FOR_EACH_METHOD(SEARCH)
        FOR_EACH_METHOD(SOURCE)
        FOR_EACH_METHOD(SUBSCRIBE)
        FOR_EACH_METHOD(TRACE)
        FOR_EACH_METHOD(UNBIND)
        FOR_EACH_METHOD(UNLINK)
        FOR_EACH_METHOD(UNLOCK)
        FOR_EACH_METHOD(UNSUBSCRIBE)

    }
#undef FOR_EACH_METHOD
    RELEASE_ASSERT_NOT_REACHED();
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_HTTPMethod_httpMethodToJS(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_HTTPMethod_httpMethodToJS_Arguments& args)
{
    return toJS(static_cast<Zig::GlobalObject*>(&context.globalObject), args.value);
}

} // namespace Bun
