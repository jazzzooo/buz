

#include "root.h"

#include "SchemaBindings.h"

namespace Bun::Bindgen::Cpp {

void bunBindgenCpp_NoOpForTesting_noop(
    CppCallContext&,
    const BunBindgenCpp_NoOpForTesting_noop_Arguments&)
{
}

JSC::JSValue bunBindgenCpp_NoOpForTesting_callback(
    CppCallContext& context,
    const BunBindgenCpp_NoOpForTesting_callback_Arguments& args)
{
    auto* callback = args.callback.getObject();
    JSC::CallData callData = JSC::getCallData(callback);
    return JSC::profiledCall(&context.globalObject, JSC::ProfilingReason::API, callback, callData, JSC::jsUndefined(), JSC::MarkedArgumentBuffer());
}

}
