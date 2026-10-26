// PerformanceMeasure implementations behind the generated bindings. The
// cell, prototype, constructor, conversions, and toJS come from
// WebCorePerformance.schema.zig; this file owns the cached detail slot.

#include "config.h"
#include "JSPerformanceMeasure.h"

#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

JSValue bunBindgenCpp_WebCorePerformance_PerformanceMeasure_getter_detail(
    CppEngineCallContext<JSPerformanceMeasure>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceMeasure_getter_detail_Arguments&)
{
    auto* global = &ctx.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    if (JSValue cached = ctx.wrapper.raw_slot_detail(); !cached.isEmpty())
        return cached;
    JSValue result = ctx.wrapped().detail(*global);
    RETURN_IF_EXCEPTION(throwScope, {});
    ctx.wrapper.set_slot_detail(JSC::getVM(global), result);
    return result;
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
