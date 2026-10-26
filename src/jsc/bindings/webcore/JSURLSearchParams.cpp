#include "config.h"
#include "JSURLSearchParams.h"

#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <algorithm>
#include <type_traits>

namespace WebCore {

using namespace JSC;

RefPtr<URLSearchParams> protectedURLSearchParams(JSGlobalObject* global, JSValue value)
{
    auto* params = Bun::Bindgen::ZigExports::bunBindgenZig_urls_urlSearchParamsRetainFromWrapper(global, value);
    if (!params)
        return nullptr;
    return adoptRef(*params);
}

struct ParameterGroups {
    struct Group {
        size_t offset;
        size_t count;
        size_t firstIndex;
    };
    Vector<size_t> order;
    Vector<Group> groups;
};

static ExceptionOr<ParameterGroups> groupParameters(const URLSearchParams& params)
{
    const auto& pairs = params.pairs();
    ParameterGroups result;
    if (!result.order.tryGrow(pairs.size()))
        return Exception { OutOfMemoryError };
    for (size_t index = 0; index < pairs.size(); ++index)
        result.order[index] = index;
    if (result.order.size() > 1) {
        std::sort(result.order.begin(), result.order.end(), [&](size_t left, size_t right) {
            auto comparison = codePointCompare(pairs[left].key, pairs[right].key);
            return comparison != 0 ? comparison < 0 : left < right;
        });
    }
    for (size_t offset = 0; offset < result.order.size();) {
        const auto firstIndex = result.order[offset];
        size_t end = offset + 1;
        while (end < result.order.size() && pairs[result.order[end]].key == pairs[firstIndex].key)
            ++end;
        if (!result.groups.tryAppend(ParameterGroups::Group { offset, end - offset, firstIndex }))
            return Exception { OutOfMemoryError };
        offset = end;
    }
    if (result.groups.size() > 1) {
        std::sort(result.groups.begin(), result.groups.end(), [](const auto& left, const auto& right) {
            return left.firstIndex < right.firstIndex;
        });
    }
    return result;
}

JSValue getInternalProperties(VM& vm, JSGlobalObject* global, JSURLSearchParams* wrapper)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto params = protectedURLSearchParams(global, wrapper);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(params);
    auto grouped = groupParameters(*params);
    if (grouped.hasException()) {
        propagateException(*global, scope, grouped.releaseException());
        return {};
    }
    auto groups = grouped.releaseReturnValue();
    auto* object = constructEmptyObject(global);
    RETURN_IF_EXCEPTION(scope, {});
    object->putDirect(vm, vm.propertyNames->toStringTagSymbol, jsNontrivialString(vm, "URLSearchParams"_s), PropertyAttribute::DontEnum | PropertyAttribute::ReadOnly);
    RETURN_IF_EXCEPTION(scope, {});
    const auto& pairs = params->pairs();
    for (const auto& group : groups.groups) {
        auto identifier = Identifier::fromString(vm, pairs[group.firstIndex].key);
        JSValue value;
        if (group.count == 1) {
            value = jsString(vm, pairs[group.firstIndex].value);
            RETURN_IF_EXCEPTION(scope, {});
        } else {
            auto* array = constructEmptyArray(global, nullptr, group.count);
            RETURN_IF_EXCEPTION(scope, {});
            for (size_t index = 0; index < group.count; ++index) {
                auto string = jsString(vm, pairs[groups.order[group.offset + index]].value);
                RETURN_IF_EXCEPTION(scope, {});
                array->putDirectIndex(global, index, string);
                RETURN_IF_EXCEPTION(scope, {});
            }
            value = array;
        }
        object->putDirectMayBeIndex(global, identifier, value);
        RETURN_IF_EXCEPTION(scope, {});
    }
    return object;
}

} // namespace WebCore

namespace Bun::Bindgen::Engine {

using namespace WebCore;

static ExceptionOr<Ref<URLSearchParams>> createURLSearchParams(const auto& init)
{
    if (init.is_string())
        return URLSearchParams::create(init.string());
    Vector<KeyValuePair<String, String>> pairs;
    if (init.is_sequence()) {
        if (!pairs.tryReserveInitialCapacity(init.sequence().size()))
            return WebCore::Exception { OutOfMemoryError };
        for (const auto& pair : init.sequence()) {
            RELEASE_ASSERT(pair.size() == 2);
            pairs.unsafeAppendWithoutCapacityCheck({ pair[0], pair[1] });
        }
    } else {
        RELEASE_ASSERT(init.is_record());
        if (!pairs.tryReserveInitialCapacity(init.record().size()))
            return WebCore::Exception { OutOfMemoryError };
        for (const auto& pair : init.record())
            pairs.unsafeAppendWithoutCapacityCheck({ pair.first, pair.second });
    }
    return URLSearchParams::create(WTF::move(pairs));
}

template<typename T>
static auto allocationResult(ExceptionOr<T>&& result)
{
    using Result = NativeAllocationResult<T>;
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == OutOfMemoryError);
        return Result { nativeAllocationFailure() };
    }
    if constexpr (std::is_void_v<T>)
        return Result {};
    else
        return Result { result.releaseReturnValue() };
}

BunBindgenEngine_WebCoreURL_urlSearchParamsCreate_Return bunBindgenEngine_WebCoreURL_urlSearchParamsCreate(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsCreate_Arguments& args)
{
    auto result = args.init ? createURLSearchParams(*args.init) : URLSearchParams::create(emptyString());
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == OutOfMemoryError);
        return nativeAllocationFailure();
    }
    return &result.releaseReturnValue().leakRef();
}

BunBindgenEngine_WebCoreURL_urlSearchParamsAppend_Return bunBindgenEngine_WebCoreURL_urlSearchParamsAppend(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsAppend_Arguments& args)
{
    return allocationResult(args.params->append(args.name, args.value));
}

BunBindgenEngine_WebCoreURL_urlSearchParamsDelete_Return bunBindgenEngine_WebCoreURL_urlSearchParamsDelete(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsDelete_Arguments& args)
{
    return allocationResult(args.params->remove(args.name, args.value.value_or(String())));
}

std::optional<String> bunBindgenEngine_WebCoreURL_urlSearchParamsGet(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsGet_Arguments& args)
{
    auto value = args.params->get(args.name);
    return value.isNull() ? std::nullopt : std::optional<String> { WTF::move(value) };
}

BunBindgenEngine_WebCoreURL_urlSearchParamsGetAll_Return bunBindgenEngine_WebCoreURL_urlSearchParamsGetAll(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsGetAll_Arguments& args)
{
    return allocationResult(args.params->getAll(args.name));
}

bool bunBindgenEngine_WebCoreURL_urlSearchParamsHas(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsHas_Arguments& args)
{
    return args.params->has(args.name, args.value.value_or(String()));
}

BunBindgenEngine_WebCoreURL_urlSearchParamsSet_Return bunBindgenEngine_WebCoreURL_urlSearchParamsSet(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsSet_Arguments& args)
{
    return allocationResult(args.params->set(args.name, args.value));
}

BunBindgenEngine_WebCoreURL_urlSearchParamsSort_Return bunBindgenEngine_WebCoreURL_urlSearchParamsSort(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsSort_Arguments& args)
{
    return allocationResult(args.params->sort());
}

BunBindgenEngine_WebCoreURL_urlSearchParamsJSON_Return bunBindgenEngine_WebCoreURL_urlSearchParamsJSON(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsJSON_Arguments& args)
{
    auto grouped = groupParameters(*args.params);
    if (grouped.hasException())
        return nativeAllocationFailure();
    auto groups = grouped.releaseReturnValue();
    const auto& pairs = args.params->pairs();
    Vector<std::pair<String, URLSearchParamsJSONValueResult>> result;
    if (!result.tryReserveInitialCapacity(groups.groups.size()))
        return nativeAllocationFailure();
    for (const auto& group : groups.groups) {
        URLSearchParamsJSONValueResult value;
        if (group.count == 1)
            value.set_value(pairs[group.firstIndex].value);
        else {
            Vector<String> values;
            if (!values.tryReserveInitialCapacity(group.count))
                return nativeAllocationFailure();
            for (size_t index = 0; index < group.count; ++index)
                values.unsafeAppendWithoutCapacityCheck(pairs[groups.order[group.offset + index]].value);
            value.set_values(WTF::move(values));
        }
        result.unsafeAppendWithoutCapacityCheck({ pairs[group.firstIndex].key, WTF::move(value) });
    }
    return result;
}

uint64_t bunBindgenEngine_WebCoreURL_urlSearchParamsSize(
    const BunBindgenEngine_WebCoreURL_urlSearchParamsSize_Arguments& args)
{
    return args.params->size();
}

} // namespace Bun::Bindgen::Engine
