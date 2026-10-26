#include "config.h"
#include "JSPerformanceEntry.h"

#include "JSDOMWrapperCache.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>

namespace WebCore {

using namespace JSC;

bool JSPerformanceEntryOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, AbstractSlotVisitor& visitor, ASCIILiteral* reason)
{
    UNUSED_PARAM(handle);
    UNUSED_PARAM(visitor);
    UNUSED_PARAM(reason);
    return false;
}

void JSPerformanceEntryOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSPerformanceEntry*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

WTF::String bunBindgenCpp_WebCorePerformance_PerformanceEntry_getter_name(
    CppEngineCallContext<JSPerformanceEntry>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceEntry_getter_name_Arguments&)
{
    return ctx.wrapped().name();
}

WTF::String bunBindgenCpp_WebCorePerformance_PerformanceEntry_getter_entryType(
    CppEngineCallContext<JSPerformanceEntry>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceEntry_getter_entryType_Arguments&)
{
    return ctx.wrapped().entryType();
}

double bunBindgenCpp_WebCorePerformance_PerformanceEntry_getter_startTime(
    CppEngineCallContext<JSPerformanceEntry>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceEntry_getter_startTime_Arguments&)
{
    return ctx.wrapped().startTime();
}

double bunBindgenCpp_WebCorePerformance_PerformanceEntry_getter_duration(
    CppEngineCallContext<JSPerformanceEntry>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceEntry_getter_duration_Arguments&)
{
    return ctx.wrapped().duration();
}

PerformanceEntryJSONDictionaryResult bunBindgenCpp_WebCorePerformance_PerformanceEntry_method_toJSON(
    CppEngineCallContext<JSPerformanceEntry>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceEntry_method_toJSON_Arguments&)
{
    auto& impl = ctx.wrapped();
    return {
        .name = String { impl.name() },
        .entryType = String { impl.entryType() },
        .startTime = impl.startTime(),
        .duration = impl.duration(),
    };
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
