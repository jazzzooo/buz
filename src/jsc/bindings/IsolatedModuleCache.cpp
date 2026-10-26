#include "IsolatedModuleCache.h"
#include "SchemaBindings.h"
#include "BunClientData.h"
#include "ModuleLoader.h"
#include "ZigSourceProvider.h"

namespace Bun {

bool IsolatedModuleCache::canUse(JSC::VM&, void* bunVM, const std::optional<WTF::String>& typeAttribute)
{
    if (!isBunTest())
        return false;
    if (!Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineUseIsolationSourceProviderCache(
            static_cast<VirtualMachine*>(bunVM)))
        return false;
    if (typeAttribute)
        return false;
    return true;
}

Zig::SourceProvider* IsolatedModuleCache::lookup(JSC::VM& vm, const WTF::String& key)
{
    auto& cache = WebCore::clientData(vm)->isolationSourceProviderCache;
    auto it = cache.find(key);
    if (it == cache.end())
        return nullptr;
    ASSERT(it->value);
    return static_cast<Zig::SourceProvider*>(it->value.get());
}

bool IsolatedModuleCache::isTagCacheable(const Bindgen::ResolvedSourceTagResult& tag)
{
    if (tag.is_builtin())
        return false;
    switch (tag.source()) {
    case Bindgen::ResolvedSourceKind::javascript:
    case Bindgen::ResolvedSourceKind::package_json_type_module:
    case Bindgen::ResolvedSourceKind::package_json_type_commonjs:
    case Bindgen::ResolvedSourceKind::esm:
        return true;
    default:
        return false;
    }
}

void IsolatedModuleCache::insert(JSC::VM& vm, const WTF::String& key, Zig::SourceProvider& provider)
{
    if (!isTagCacheable(provider.m_resolvedSource.tag))
        return;
    auto result = WebCore::clientData(vm)->isolationSourceProviderCache.add(key, RefPtr<JSC::SourceProvider>(&provider));
    ASSERT_WITH_MESSAGE(result.isNewEntry, "IsolatedModuleCache::insert for already-cached key — a lookup was bypassed");
    UNUSED_VARIABLE(result);
}

void IsolatedModuleCache::evict(JSC::VM& vm, const WTF::String& key)
{
    WebCore::clientData(vm)->isolationSourceProviderCache.remove(key);
}

void IsolatedModuleCache::clear(JSC::VM& vm)
{
    WebCore::clientData(vm)->isolationSourceProviderCache.clear();
}

} // namespace Bun
