#include "root.h"
#include "SchemaBindings.h"
#include "JavaScriptCore/JSObject.h"
#include "JavaScriptCore/JSFunction.h"
#include "JavaScriptCore/JSString.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSGlobalObject.h"
#include "ZigGlobalObject.h"

namespace Bun {

using namespace JSC;

JSC::JSValue Bindgen::Engine::bunBindgenEngine_ConsoleObject_callCustomInspectFunction(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_ConsoleObject_callCustomInspectFunction_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSFunction* stylizeFn = args.colors ? globalObject->utilInspectStylizeColorFunction() : globalObject->utilInspectStylizeNoColorFunction();
    RETURN_IF_EXCEPTION(scope, {});

    JSFunction* inspectFn = globalObject->utilInspectFunction();
    RETURN_IF_EXCEPTION(scope, {});
    JSFunction* invoke = globalObject->utilInspectCallCustomFunction();
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(stylizeFn && inspectFn && invoke);
    MarkedArgumentBuffer arguments;
    arguments.append(args.function);
    arguments.append(jsNumber(args.depth));
    arguments.append(jsNumber(args.maxDepth));
    arguments.append(jsBoolean(args.colors));
    arguments.append(jsBoolean(args.sorted));
    arguments.append(jsBoolean(args.compact));
    arguments.append(inspectFn);
    arguments.append(stylizeFn);

    auto inspectRet = JSC::profiledCall(globalObject, ProfilingReason::API, invoke, JSC::getCallData(invoke), args.thisValue, arguments);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, inspectRet);
}

}
