#pragma once
#include "root.h"
#include "JavaScriptCore/SourceOrigin.h"
#include <JavaScriptCore/ExceptionHelpers.h>
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"

namespace Bake {

class DevServerSourceProvider final : public JSC::StringSourceProvider {
public:
    static RefPtr<DevServerSourceProvider> create(
        JSC::JSGlobalObject* globalObject,
        const String& source,
        std::span<const uint8_t> sourceMapJSON,
        const JSC::SourceOrigin& sourceOrigin,
        String&& sourceURL,
        const TextPosition& startPosition,
        JSC::SourceProviderSourceType sourceType)
    {
        auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
        auto provider = adoptRef(*new DevServerSourceProvider(source, sourceOrigin, WTF::move(sourceURL), startPosition, sourceType));
        auto* zigGlobalObject = uncheckedDowncast<::Zig::GlobalObject>(globalObject);
        provider->m_bunVM = zigGlobalObject->bunVM();
        provider->m_specifier = provider->sourceURL();
        auto registered = Bun::Bindgen::ZigExports::bunBindgenZig_source_providers_addDevServerSourceProvider(provider->m_bunVM, source, provider->m_specifier, sourceMapJSON);
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
    DevServerSourceProvider(
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

    ~DevServerSourceProvider()
    {
        if (m_sourceMapRegistration)
            Bun::Bindgen::ZigExports::bunBindgenZig_source_providers_removeSourceMapRegistration(m_bunVM, m_sourceMapRegistration, m_specifier);
    }

    VirtualMachine* m_bunVM = nullptr;
    uint64_t m_sourceMapRegistration = 0;
    WTF::String m_specifier;
};

} // namespace Bake
