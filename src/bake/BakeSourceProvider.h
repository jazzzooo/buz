#pragma once
#include "root.h"
#include "BakeGlobalObject.h"
#include "JavaScriptCore/SourceOrigin.h"
#include <JavaScriptCore/ExceptionHelpers.h>
#include "SchemaBindings.h"

namespace Bake {

class SourceProvider final : public JSC::StringSourceProvider {
public:
    static RefPtr<SourceProvider> create(
        JSC::JSGlobalObject* globalObject,
        const String& source,
        const JSC::SourceOrigin& sourceOrigin,
        String&& sourceURL,
        const TextPosition& startPosition,
        JSC::SourceProviderSourceType sourceType)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
        auto provider = adoptRef(*new SourceProvider(source, sourceOrigin, WTF::move(sourceURL), startPosition, sourceType));
        auto* zigGlobalObject = uncheckedDowncast<Zig::GlobalObject>(globalObject);
        provider->m_bunVM = zigGlobalObject->bunVM();
        auto* bakeGlobalObject = dynamicDowncast<Bake::GlobalObject>(globalObject);
        std::optional<Bun::BakePerThreadData*> perThreadData;
        if (bakeGlobalObject && bakeGlobalObject->m_perThreadData)
            perThreadData = bakeGlobalObject->m_perThreadData;
        auto registered = Bun::Bindgen::ZigExports::bunBindgenZig_source_providers_addBakeSourceProviderSourceMap(provider->m_bunVM, source, provider->sourceURL(), perThreadData);
        if (registered)
            provider->m_sourceMapRegistration = *registered;
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!registered) {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return nullptr;
        }
        return WTF::move(provider);
    }

private:
    ~SourceProvider()
    {
        if (m_sourceMapRegistration)
            Bun::Bindgen::ZigExports::bunBindgenZig_source_providers_removeSourceMapRegistration(m_bunVM, m_sourceMapRegistration, sourceURL());
    }

    SourceProvider(
        const String& source,
        const JSC::SourceOrigin& sourceOrigin,
        String&& sourceURL,
        const TextPosition& startPosition,
        JSC::SourceProviderSourceType sourceType)
        : StringSourceProvider(
              source,
              sourceOrigin,
              JSC::SourceTaintedOrigin::Untainted,
              WTF::move(sourceURL),
              startPosition,
              sourceType)
    {
    }

    VirtualMachine* m_bunVM = nullptr;
    uint64_t m_sourceMapRegistration = 0;
};

} // namespace Bake
