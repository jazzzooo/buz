#include "root.h"
#include "BunSecureContextCache.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/WeakGCMapInlines.h>

using namespace JSC;

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_SecureContext_secureContextCacheGet(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_SecureContext_secureContextCacheGet_Arguments& args)
{
    auto* global = defaultGlobalObject(&context.globalObject);
    auto& slot = global->m_secureContextCache;
    if (!slot)
        return std::nullopt;
    if (auto* object = slot->get(args.key))
        return JSC::JSValue(object);
    return std::nullopt;
}

void Bun::Bindgen::Engine::bunBindgenEngine_SecureContext_secureContextCacheSet(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_SecureContext_secureContextCacheSet_Arguments& args)
{
    auto* global = defaultGlobalObject(&context.globalObject);
    auto& slot = global->m_secureContextCache;
    if (!slot)
        slot = makeUnique<Bun::SecureContextCache>(global->vm());
    auto value = context.classValue(args.value);
    auto* object = value.getObject();
    RELEASE_ASSERT(object);
    slot->set(args.key, object);
}
