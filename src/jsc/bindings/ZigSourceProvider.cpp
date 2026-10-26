#include "root.h"

#include "helpers.h"

#include "SchemaBindings.h"
#include "ZigSourceProvider.h"

#include "ZigGlobalObject.h"
#include "wtf/Assertions.h"

#include <JavaScriptCore/Completion.h>
#include <wtf/text/StringHash.h>
#include <JavaScriptCore/SourceCodeKey.h>
#include <JavaScriptCore/CodeCache.h>

void Bun::Bindgen::Engine::releaseModuleInfoDeserialized(bun_ModuleInfoDeserialized* moduleInfo)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_compiler_module_records_compilerArtifactDestroy(moduleInfo);
}

namespace Zig {

using SourceOrigin = JSC::SourceOrigin;
using String = WTF::String;

SourceOrigin toSourceOrigin(const String& sourceURL, bool isBuiltin)
{

    ASSERT_WITH_MESSAGE(!sourceURL.startsWith("file://"_s), "specifier should not already be a file URL");

    if (isBuiltin) {
        if (sourceURL.startsWith("node:"_s)) {
            return SourceOrigin(WTF::URL(makeString("builtin://node/"_s, sourceURL.substring(5))));
        } else if (sourceURL.startsWith("bun:"_s)) {
            return SourceOrigin(WTF::URL(makeString("builtin://bun/"_s, sourceURL.substring(4))));
        } else {
            return SourceOrigin(WTF::URL(makeString("builtin://"_s, sourceURL)));
        }
    }
    return SourceOrigin(WTF::URL::fileURLWithFileSystemPath(sourceURL));
}

JSC::SourceID sourceIDForSourceURL(const WTF::String& sourceURL)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_code_coverage_byteRangeMappingSourceID(sourceURL).value_or(0);
}

RefPtr<SourceProvider> SourceProvider::create(
    Zig::GlobalObject* globalObject,
    ResolvedSource&& resolvedSource,
    JSC::SourceProviderSourceType sourceType,
    bool isBuiltin)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    // Use BunTranspiledModule when module_info is present.
    // This allows JSC to skip parsing during the analyze phase (uses pre-computed imports/exports).
    // Bytecode cache (if present) is used separately during the evaluate phase.
    if (resolvedSource.moduleInfo) {
        ASSERT(!resolvedSource.isCommonJSModule);
        sourceType = JSC::SourceProviderSourceType::BunTranspiledModule;
    }

    const auto string = resolvedSource.sourceCode;
    const auto sourceURLString = resolvedSource.sourceURL;
    const bool alreadyBundled = resolvedSource.alreadyBundled;

    bool isCodeCoverageEnabled = !!globalObject->vm().controlFlowProfiler();

    bool shouldGenerateCodeCoverage = false;
    if (isCodeCoverageEnabled && !isBuiltin) {
        auto enabled = Bun::Bindgen::ZigExports::bunBindgenZig_code_coverage_codeCoverageShouldGenerate(sourceURLString);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!enabled) {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return nullptr;
        }
        shouldGenerateCodeCoverage = *enabled;
    }

    // Compute source origin: use explicit bytecodeOriginPath if provided, otherwise derive from sourceURL.
    // bytecodeOriginPath is used for bytecode cache validation where the origin must match
    // exactly what was used at build time.
    const auto getSourceOrigin = [&]() -> SourceOrigin {
        const auto& bytecodeOriginPath = resolvedSource.bytecodeOriginPath;
        if (!bytecodeOriginPath.isNull() && !bytecodeOriginPath.isEmpty()) {
            // Convert file path to file:// URL (same as build time)
            return SourceOrigin(WTF::URL::fileURLWithFileSystemPath(bytecodeOriginPath));
        }
        return toSourceOrigin(sourceURLString, isBuiltin);
    };

    const auto getProvider = [&]() -> Ref<SourceProvider> {
        if (resolvedSource.bytecodeCache) {
            auto* cache = *resolvedSource.bytecodeCache;
            resolvedSource.bytecodeCache.reset();
            auto origin = getSourceOrigin();
            const auto bytes = Bun::Bindgen::Engine::externalBytesOwnerBytes(cache);
            Ref<JSC::CachedBytecode> bytecode = JSC::CachedBytecode::create(
                std::span<uint8_t>(const_cast<uint8_t*>(bytes.data()), bytes.size()),
                [cache](const void*) { Bun::Bindgen::Engine::releaseExternalBytesOwner(cache); },
                {});
            auto provider = adoptRef(*new SourceProvider(
                globalObject->bunVM(),
                WTF::move(resolvedSource),
                string.isNull() ? *StringImpl::empty() : *string.impl(),
                JSC::SourceTaintedOrigin::Untainted,
                origin,
                sourceURLString.impl(), TextPosition(),
                sourceType));
            provider->m_cachedBytecode = WTF::move(bytecode);
            return provider;
        }

        return adoptRef(*new SourceProvider(
            globalObject->bunVM(),
            WTF::move(resolvedSource),
            string.isNull() ? *StringImpl::empty() : *string.impl(),
            JSC::SourceTaintedOrigin::Untainted,
            getSourceOrigin(),
            sourceURLString.impl(), TextPosition(),
            sourceType));
    };

    auto provider = getProvider();

    if (shouldGenerateCodeCoverage) {
        auto generated = Bun::Bindgen::ZigExports::bunBindgenZig_code_coverage_byteRangeMappingGenerate(provider->sourceURL(), provider->source().toStringWithoutCopying(), provider->asID());
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!generated) {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return nullptr;
        }
    }

    if (alreadyBundled) {
        auto registered = Bun::Bindgen::ZigExports::bunBindgenZig_source_providers_addSourceProviderSourceMap(globalObject->bunVM(), provider->source().toStringWithoutCopying(), sourceURLString);
        if (registered)
            provider->m_sourceMapRegistration = *registered;
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!registered) {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return nullptr;
        }
    }

    RETURN_IF_EXCEPTION(scope, nullptr);
    return WTF::move(provider);
}

StringView SourceProvider::source() const
{
    return StringView(m_source.get());
}

SourceProvider::~SourceProvider()
{
    if (m_sourceMapRegistration) {
        Bun::Bindgen::ZigExports::bunBindgenZig_source_providers_removeSourceMapRegistration(m_bunVM, m_sourceMapRegistration, sourceURL());
    }
    releaseResolvedSourceResources(m_resolvedSource);
}

} // namespace Zig

static JSC::VM& getVMForBytecodeCache()
{
    static thread_local JSC::VM* vmForBytecodeCache = nullptr;
    if (!vmForBytecodeCache) {
        const auto heapSize = JSC::HeapType::Small;
        auto vmPtr = JSC::VM::tryCreate(heapSize);
        vmPtr->refSuppressingSaferCPPChecking();
        vmForBytecodeCache = vmPtr.get();
        vmPtr->heap.acquireAccess();
    }
    return *vmForBytecodeCache;
}

Bun::Bindgen::Engine::BunBindgenEngine_cached_bytecode_generateCachedBytecode_Return Bun::Bindgen::Engine::bunBindgenEngine_cached_bytecode_generateCachedBytecode(
    const Bun::Bindgen::Engine::BunBindgenEngine_cached_bytecode_generateCachedBytecode_Arguments& args)
{
    std::span<const Latin1Character> sourceCodeSpan(reinterpret_cast<const Latin1Character*>(args.source.data()), args.source.size());
    JSC::SourceCode sourceCode = JSC::makeSource(WTF::String(sourceCodeSpan), Zig::toSourceOrigin(args.sourceProviderURL, false), JSC::SourceTaintedOrigin::Untainted);

    JSC::VM& vm = getVMForBytecodeCache();
    JSC::JSLockHolder locker(vm);
    WTF::RefPtr<JSC::CachedBytecode> cachedBytecode;
    switch (args.kind) {
    case decltype(args.kind)::esm: {
        JSC::ParserError parserError;
        auto* unlinkedCodeBlock = JSC::recursivelyGenerateUnlinkedCodeBlockForModuleProgram(
            vm,
            sourceCode,
            JSC::StrictModeLexicallyScopedFeature,
            JSC::JSParserScriptMode::Module,
            {},
            parserError,
            JSC::EvalContextType::None);
        if (parserError.isValid() || !unlinkedCodeBlock)
            return std::nullopt;
        auto key = JSC::sourceCodeKeyForSerializedModule(vm, sourceCode);
        dataLogLnIf(JSC::Options::verboseDiskCache(), "[Bytecode Build] generateModule url=", args.sourceProviderURL, " origin=", sourceCode.provider()->sourceOrigin().url().string(), " sourceSize=", args.source.size(), " keyHash=", key.hash());
        cachedBytecode = JSC::encodeCodeBlock(vm, key, unlinkedCodeBlock);
        break;
    }
    case decltype(args.kind)::cjs: {
        JSC::ParserError parserError;
        auto* unlinkedCodeBlock = JSC::recursivelyGenerateUnlinkedCodeBlockForProgram(
            vm,
            sourceCode,
            JSC::NoLexicallyScopedFeatures,
            JSC::JSParserScriptMode::Classic,
            {},
            parserError,
            JSC::EvalContextType::None);
        if (parserError.isValid() || !unlinkedCodeBlock)
            return std::nullopt;
        auto key = JSC::sourceCodeKeyForSerializedProgram(vm, sourceCode);
        dataLogLnIf(JSC::Options::verboseDiskCache(), "[Bytecode Build] generateCJS url=", args.sourceProviderURL, " origin=", sourceCode.provider()->sourceOrigin().url().string(), " sourceSize=", args.source.size(), " keyHash=", key.hash());
        cachedBytecode = JSC::encodeCodeBlock(vm, key, unlinkedCodeBlock);
        break;
    }
    }
    if (!cachedBytecode)
        return std::nullopt;

    return cachedBytecode.leakRef();
}

std::span<const uint8_t> Bun::Bindgen::Engine::cachedBytecodeBytes(JSC::CachedBytecode* cachedBytecode)
{
    RELEASE_ASSERT(cachedBytecode);
    return cachedBytecode->span();
}

void Bun::Bindgen::Engine::releaseCachedBytecode(JSC::CachedBytecode* cachedBytecode)
{
    RELEASE_ASSERT(cachedBytecode);
    cachedBytecode->deref();
}

namespace Zig {

unsigned SourceProvider::hash() const
{
    return m_source->hash();
}

} // namespace Zig
