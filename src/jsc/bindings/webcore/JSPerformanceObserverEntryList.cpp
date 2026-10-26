#include "config.h"
#include "JSPerformanceEntry.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Cpp {

using namespace JSC;
using namespace WebCore;

static CppResultSequence<JSValue> performanceObserverEntryListResult(
    CppCallContext& ctx,
    std::span<PerformanceEntry* const> entries,
    const String& name = {},
    const String& entryType = {})
{
    auto& global = ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    CppResultSequence<JSValue> result;
    std::optional<PerformanceEntry::Type> type;
    if (!entryType.isNull()) {
        type = PerformanceEntry::parseEntryTypeString(entryType);
        if (!type)
            return result;
    }
    if (!result.reserveCapacity(ctx.results(), entries.size()))
        return {};
    auto* domGlobal = defaultGlobalObject(&global);
    for (const auto& entry : entries) {
        RELEASE_ASSERT(entry);
        if (!name.isNull() && entry->name() != name)
            continue;
        if (type && entry->performanceEntryType() != *type)
            continue;
        auto value = toJS(&global, domGlobal, *entry);
        RETURN_IF_EXCEPTION(scope, {});
        if (!result.append(ctx.results(), value))
            return {};
    }
    return result;
}

PerformanceObserverEntryListSnapshotResult bunBindgenCpp_WebCorePerformance_createObserverEntryList(
    CppCallContext&,
    const BunBindgenCpp_WebCorePerformance_createObserverEntryList_Arguments& args)
{
    return { .entries = args.entries };
}

CppResultSequence<JSValue> bunBindgenCpp_PerformanceObserverEntryList_PerformanceObserverEntryList_method_getEntries(
    CppCallContext& ctx,
    const BunBindgenCpp_PerformanceObserverEntryList_PerformanceObserverEntryList_method_getEntries_Arguments& args)
{
    return performanceObserverEntryListResult(ctx, args.bindingThis.entries.span());
}

CppResultSequence<JSValue> bunBindgenCpp_PerformanceObserverEntryList_PerformanceObserverEntryList_method_getEntriesByType(
    CppCallContext& ctx,
    const BunBindgenCpp_PerformanceObserverEntryList_PerformanceObserverEntryList_method_getEntriesByType_Arguments& args)
{
    return performanceObserverEntryListResult(ctx, args.bindingThis.entries.span(), {}, args.type);
}

CppResultSequence<JSValue> bunBindgenCpp_PerformanceObserverEntryList_PerformanceObserverEntryList_method_getEntriesByName(
    CppCallContext& ctx,
    const BunBindgenCpp_PerformanceObserverEntryList_PerformanceObserverEntryList_method_getEntriesByName_Arguments& args)
{
    return performanceObserverEntryListResult(ctx, args.bindingThis.entries.span(), args.name, args.type.value_or(String {}));
}

} // namespace Bun::Bindgen::Cpp
