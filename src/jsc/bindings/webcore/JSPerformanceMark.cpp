// PerformanceMark implementations behind the generated bindings. The cell,
// prototype, constructor, options-dictionary conversion, and toJS come from
// WebCorePerformance.schema.zig; this file owns construction and the cached
// detail slot.

#include "config.h"
#include "JSPerformanceMark.h"

#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "PerformanceMarkOptions.h"
#include "SchemaBindings.h"
#include "ScriptExecutionContext.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

JSPerformanceMark* bunBindgenCpp_WebCorePerformance_PerformanceMark_construct(
    CppEngineConstructContext<JSPerformanceMark>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceMark_construct_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* zigGlobal = defaultGlobalObject(global);
    auto* context = zigGlobal->scriptExecutionContext();
    if (!context) [[unlikely]] {
        throwConstructorScriptExecutionContextUnavailableError(*global, throwScope, "PerformanceMark"_s);
        return nullptr;
    }

    PerformanceMarkOptions options;
    if (const auto& dict = args.markOptions) {
        options.detail = dict->detail;
        options.startTime = dict->start_time;
    } else {
        options.detail = jsUndefined();
    }

    auto result = PerformanceMark::create(*global, *context, args.markName, std::optional { WTF::move(options) });
    if (result.hasException()) [[unlikely]] {
        propagateException(*global, throwScope, result.releaseException());
        return nullptr;
    }
    auto impl = result.releaseReturnValue();
    auto* implPtr = impl.ptr();
    auto* wrapper = JSPerformanceMark::create(ctx.structure, zigGlobal, WTF::move(impl));
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    return wrapper;
}

JSValue bunBindgenCpp_WebCorePerformance_PerformanceMark_getter_detail(
    CppEngineCallContext<JSPerformanceMark>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceMark_getter_detail_Arguments&)
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
