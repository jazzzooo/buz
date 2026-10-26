#include "root.h"

#include "SchemaBindings.h"
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSONObject.h>

namespace Bun {

WTF::String Bindgen::Engine::bunBindgenEngine_Response_jsonStringify(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_Response_jsonStringify_Arguments& args)
{
    auto& global = context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto value = args.value;
    if (value.isUndefined() || value.isSymbol() || (value.isCell() && value.asCell()->type() == JSC::JSFunctionType)) {
        JSC::throwTypeError(&global, scope, "Value is not JSON serializable"_s);
        return {};
    }
    if (value.isBigInt()) {
        JSC::throwTypeError(&global, scope, "Do not know how to serialize a BigInt"_s);
        return {};
    }
    RELEASE_AND_RETURN(scope, JSC::JSONStringify(&global, value, JSC::jsUndefined()));
}

}
