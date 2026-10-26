#pragma once

#include "root.h"
#include <optional>
#include <wtf/text/WTFString.h>

namespace Bun::Bindgen {
class ResolvedSourceTagResult;
}

namespace Zig {
class SourceProvider;
}

namespace Bun {

// Per-VM cache mapping resolved specifier (absolute path) → Zig::SourceProvider,
// populated only under `bun test --isolate`. Survives global swaps so a fresh
// global's module fetch reuses an already-transpiled provider (and hits JSC's
// CodeCache + transpiled-module analysis for module_info) instead of
// re-running the native transpiler.
//
// Storage lives on JSVMClientData; this class is a stateless facade so the
// gating, key, and tag-cacheability decisions live in exactly one place. The
// map stores Zig::SourceProvider directly (not a wrapper struct) — everything
// callers need to branch on (sourceType(), m_resolvedSource.tag, module_info)
// already lives on the provider.
class IsolatedModuleCache {
public:
    // The single gate. False if the feature flag is off, --isolate isn't
    // active, or a type attribute is present (different output for
    // the same path → not cacheable by path alone).
    static bool canUse(JSC::VM&, void* bunVM, const std::optional<WTF::String>& typeAttribute = std::nullopt);

    // Only tags whose provider holds JS transpiled from the on-disk file at
    // the cache key. Loader-specific outputs (File, JSON, Object*, custom CJS
    // extensions, Wasm, builtins) are excluded — they can be produced for the
    // same path via `with {type: ...}` or require.extensions, and the lookup is
    // keyed by path alone, so caching them would let a later default-loader
    // import of that path hit the wrong provider.
    static bool isTagCacheable(const Bindgen::ResolvedSourceTagResult&);

    static Zig::SourceProvider* lookup(JSC::VM&, const WTF::String& key);

    // Inserts only when isTagCacheable(provider.m_resolvedSource.tag); no-op
    // otherwise. Asserts isNewEntry — a duplicate insert means a lookup was
    // bypassed, which is exactly the gating bug this consolidation prevents.
    static void insert(JSC::VM&, const WTF::String& key, Zig::SourceProvider&);

    static void evict(JSC::VM&, const WTF::String& key);
    static void clear(JSC::VM&);
};

} // namespace Bun
