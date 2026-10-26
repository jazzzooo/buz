#include "root.h"
#include "SchemaBindings.h"

#include <JavaScriptCore/BuiltinUtils.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGlobalObject.h>

#include "ZigGlobalObject.h"

#include "BindgenFunctionTable.h"
#include "wtf/Assertions.h"

namespace Bun {
namespace BuiltinBindingResolver {

static JSC::JSValue resolve(JSC::JSGlobalObject* lexicalGlobalObject, int32_t id)
{
    RELEASE_ASSERT(
        id < BINDGEN_BUILTIN_FACTORY_COUNT && id >= 0,
        "Invalid generated builtin binding factory id '%d'",
        id);
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    return BindgenBuiltinFactories::resolve(id, globalObject);
}

}
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_BuiltinBindingResolver_resolve(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_BuiltinBindingResolver_resolve_Arguments& args)
{
    return Bun::BuiltinBindingResolver::resolve(&context.globalObject, args.target);
}
