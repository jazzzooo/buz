#include "JSConnectionsListConstructor.h"
#include "JSConnectionsList.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSSet.h>

namespace Bun {

using namespace JSC;

const ClassInfo JSConnectionsListConstructor::s_info = { "ConnectionsList"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSConnectionsListConstructor) };

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_connectionsListConstructorCall(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_connectionsListConstructorCall_Arguments&)
{
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeHTTP_connectionsListConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_connectionsListConstructorConstruct_Arguments&)
{
    auto* lexicalGlobalObject = &context.globalObject;
    VM& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    Structure* structure = globalObject->m_JSConnectionsListClassStructure.get(globalObject);

    JSSet* allConnections = JSSet::create(vm, lexicalGlobalObject->setStructure());
    RETURN_IF_EXCEPTION(scope, {});

    JSSet* activeConnections = JSSet::create(vm, lexicalGlobalObject->setStructure());
    RETURN_IF_EXCEPTION(scope, {});

    return JSConnectionsList::create(vm, globalObject, structure, allConnections, activeConnections);
}

} // namespace Bun
