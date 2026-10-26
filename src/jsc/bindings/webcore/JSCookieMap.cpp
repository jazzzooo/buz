#include "config.h"
#include "JSCookieMap.h"

#include "JSCookie.h"
#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/PropertySlot.h>
#include <new>

namespace WebCore {

using namespace JSC;

RefPtr<CookieMap> protectedCookieMap(JSGlobalObject* global, JSValue value)
{
    auto* map = Bun::Bindgen::ZigExports::bunBindgenZig_cookie_map_cookieMapRetainFromWrapper(global, value);
    if (!map)
        return nullptr;
    return adoptRef(*map);
}

JSValue getInternalProperties(VM& vm, JSGlobalObject* global, JSCookieMap* wrapper)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto map = protectedCookieMap(global, wrapper);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(map);
    auto* object = constructEmptyObject(global);
    RETURN_IF_EXCEPTION(scope, {});
    auto iterator = map->createIterator();
    while (auto entry = iterator.next()) {
        const auto key = Identifier::fromString(vm, entry->key);
        PropertySlot slot(object, PropertySlot::InternalMethodType::GetOwnProperty);
        const bool exists = JSObject::getOwnPropertySlot(object, global, key, slot);
        RETURN_IF_EXCEPTION(scope, {});
        if (!exists) {
            auto* value = jsString(vm, entry->value);
            RETURN_IF_EXCEPTION(scope, {});
            object->putDirectMayBeIndex(global, key, value);
        }
        RETURN_IF_EXCEPTION(scope, {});
    }
    return object;
}

} // namespace WebCore

namespace Bun::Bindgen::Engine {

using namespace JSC;
using namespace WebCore;

static CookieMap* finishCookieMapCreation(
    EngineCallContext& context,
    ExceptionOr<Ref<CookieMap>>&& result)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    if (result.hasException()) [[unlikely]] {
        propagateException(context.globalObject, scope, result.releaseException());
        return nullptr;
    }

    return &result.releaseReturnValue().leakRef();
}

CookieMap* bunBindgenEngine_cookie_map_cookieMapCreate(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_map_cookieMapCreate_Arguments&)
{
    return finishCookieMapCreation(context, CookieMap::create());
}

CookieMap* bunBindgenEngine_cookie_map_cookieMapCreateString(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_map_cookieMapCreateString_Arguments& args)
{
    return finishCookieMapCreation(context, CookieMap::create(StringView(args.input)));
}

CookieMap* bunBindgenEngine_cookie_map_cookieMapCreatePairs(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_map_cookieMapCreatePairs_Arguments& args)
{
    return finishCookieMapCreation(context, CookieMap::create(args.input));
}

CookieMap* bunBindgenEngine_cookie_map_cookieMapCreateRecord(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_map_cookieMapCreateRecord_Arguments& args)
{
    return finishCookieMapCreation(context, CookieMap::create(args.input.span()));
}

CookieMap* bunBindgenEngine_cookie_map_cookieMapClone(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_map_cookieMapClone_Arguments& args)
{
    return finishCookieMapCreation(context, args.cookieMap->clone());
}

std::optional<String> bunBindgenEngine_cookie_map_cookieMapGet(
    const BunBindgenEngine_cookie_map_cookieMapGet_Arguments& args)
{
    return args.cookieMap->get(args.name);
}

size_t bunBindgenEngine_cookie_map_cookieMapSize(const BunBindgenEngine_cookie_map_cookieMapSize_Arguments& args)
{
    return args.cookieMap->size();
}

size_t bunBindgenEngine_cookie_map_cookieMapMemoryCost(const BunBindgenEngine_cookie_map_cookieMapMemoryCost_Arguments& args)
{
    return args.cookieMap->memoryCost();
}

void bunBindgenEngine_cookie_map_cookieMapSetCookie(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_map_cookieMapSetCookie_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    propagateException(context.globalObject, scope, args.cookieMap->set(Ref<Cookie>(*args.cookie)));
}

void bunBindgenEngine_cookie_map_cookieMapDelete(
    EngineCallContext& context,
    const BunBindgenEngine_cookie_map_cookieMapDelete_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    CookieStoreDeleteOptions options;
    options.name = args.name;
    options.domain = args.domain.value_or(String {});
    options.path = args.path.value_or("/"_s);
    propagateException(context.globalObject, scope, args.cookieMap->remove(options));
}

BunBindgenEngine_cookie_map_cookieMapJSON_Return bunBindgenEngine_cookie_map_cookieMapJSON(
    const BunBindgenEngine_cookie_map_cookieMapJSON_Arguments& args)
{
    WTF::Vector<std::pair<WTF::String, WTF::String>> result;
    if (!result.tryReserveInitialCapacity(args.cookieMap->size()))
        return Bun::Bindgen::nativeAllocationFailure();
    auto iterator = args.cookieMap->createIterator();
    while (auto entry = iterator.next())
        result.unsafeAppendWithoutCapacityCheck(std::pair { WTF::move(entry->key), WTF::move(entry->value) });
    return result;
}

} // namespace Bun::Bindgen::Engine

WTF::Vector<WTF::String> Bun::Bindgen::Engine::bunBindgenEngine_cookie_map_cookieMapPrepareHeaders(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_cookie_map_cookieMapPrepareHeaders_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto result = args.cookieMap->toSetCookieHeaders();
    if (result.hasException()) {
        WebCore::propagateException(context.globalObject, scope, result.releaseException());
        return {};
    }
    return result.releaseReturnValue();
}

WebCore::CookieMap* Bun::Bindgen::Engine::bunBindgenEngine_cookie_map_cookieMapRetain(
    const BunBindgenEngine_cookie_map_cookieMapRetain_Arguments& args)
{
    args.cookieMap->ref();
    return args.cookieMap;
}

void Bun::Bindgen::Engine::releaseCookieMap(WebCore::CookieMap* cookieMap)
{
    cookieMap->deref();
}

void Bun::Bindgen::Engine::releaseCookieMapIterator(WebCore::CookieMap::Iterator* iterator)
{
    delete iterator;
}

Bun::Bindgen::Engine::BunBindgenEngine_cookie_map_cookieMapIteratorCreate_Return Bun::Bindgen::Engine::bunBindgenEngine_cookie_map_cookieMapIteratorCreate(
    const BunBindgenEngine_cookie_map_cookieMapIteratorCreate_Arguments& args)
{
    auto* iterator = new (std::nothrow) WebCore::CookieMap::Iterator(*args.cookieMap);
    if (!iterator)
        return Bun::Bindgen::nativeAllocationFailure();
    return iterator;
}

Bun::Bindgen::Engine::BunBindgenEngine_cookie_map_cookieMapIteratorNext_Return Bun::Bindgen::Engine::bunBindgenEngine_cookie_map_cookieMapIteratorNext(
    const BunBindgenEngine_cookie_map_cookieMapIteratorNext_Arguments& args)
{
    auto entry = args.iterator->next();
    if (!entry)
        return std::nullopt;
    using Entry = BunBindgenEngine_cookie_map_cookieMapIteratorNext_Return::value_type::value_type;
    return Entry { .key = WTF::move(entry->key), .value = WTF::move(entry->value) };
}
