#pragma once

#include "NodeVMScript.h"
#include "SchemaBindings.h"

#include <JavaScriptCore/ObjectConstructor.h>

namespace Bun::NodeVM {

struct ResolvedContextInput {
    JSC::JSObject* sandbox;
    bool notContextified;
};

struct ResolvedScriptOptions {
    ScriptOptions options;
    JSC::JSValue importer;
};

struct ResolvedCompileFunctionOptions {
    CompileFunctionOptions options;
    JSC::JSValue importer;
};

struct ResolvedContextOptions {
    NodeVMContextOptions options;
    JSC::JSValue importer;
};

inline JSC::JSValue resolveDynamicImportOption(const std::optional<Bindgen::NodeVMDynamicImportOption>& input)
{
    if (!input)
        return JSC::jsUndefined();
    if (input->is_callback())
        return input->callback();
    RELEASE_ASSERT(input->is_default_loader());
    return input->default_loader();
}

inline NodeVMContextOptions resolveCodeGenerationOptions(const std::optional<Bindgen::NodeVMCodeGenerationOptions>& input)
{
    NodeVMContextOptions result;
    if (input) {
        result.allowStrings = input->strings;
        result.allowWasm = input->wasm;
    }
    return result;
}

inline ResolvedContextInput resolveContextInput(JSC::JSGlobalObject* globalObject, const Bindgen::NodeVMContextInput& input)
{
    if (input.is_object())
        return { JSC::asObject(input.object()), false };

    RELEASE_ASSERT(input.is_dont_contextify() || input.is_defaulted());
    return { JSC::constructEmptyObject(globalObject), input.is_dont_contextify() };
}

inline ResolvedScriptOptions resolveScriptOptions(const Bindgen::NodeVMScriptOptionsInput& input)
{
    if (input.is_filename())
        return { ScriptOptions(input.filename()), JSC::jsUndefined() };
    if (input.is_defaulted())
        return { ScriptOptions("evalmachine.<anonymous>"_s), JSC::jsUndefined() };

    RELEASE_ASSERT(input.is_options());
    const auto& source = input.options();
    ScriptOptions result(
        source.filename,
        OrdinalNumber::fromZeroBasedInt(source.line_offset),
        OrdinalNumber::fromZeroBasedInt(source.column_offset));
    result.timeout = source.timeout;
    result.produceCachedData = source.produce_cached_data;
    if (source.cached_data)
        result.cachedData = *source.cached_data;
    return { WTF::move(result), resolveDynamicImportOption(source.import_module_dynamically) };
}

inline std::optional<ResolvedCompileFunctionOptions> resolveCompileFunctionOptions(JSC::JSGlobalObject* globalObject, const Bindgen::NodeVMCompileFunctionOptionsInput& input)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (input.is_defaulted()) {
        CompileFunctionOptions result(""_s);
        result.parsingContext = globalObject;
        return ResolvedCompileFunctionOptions { WTF::move(result), JSC::jsUndefined() };
    }

    RELEASE_ASSERT(input.is_options());
    const auto& source = input.options();
    CompileFunctionOptions result(
        source.filename,
        OrdinalNumber::fromZeroBasedInt(source.line_offset),
        OrdinalNumber::fromZeroBasedInt(source.column_offset));
    result.parsingContext = globalObject;
    result.produceCachedData = source.produce_cached_data;
    if (source.cached_data)
        result.cachedData = *source.cached_data;
    if (source.parsing_context) {
        result.parsingContext = getGlobalObjectFromContext(globalObject, *source.parsing_context, false);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        RELEASE_ASSERT(result.parsingContext);
    }
    if (source.context_extensions) {
        auto& vm = globalObject->vm();
        result.contextExtensions.reserveInitialCapacity(source.context_extensions->size());
        for (auto extension : *source.context_extensions)
            result.contextExtensions.append(JSC::Strong<JSC::JSObject> { vm, JSC::asObject(extension) });
    }
    return ResolvedCompileFunctionOptions { WTF::move(result), resolveDynamicImportOption(source.import_module_dynamically) };
}

inline ResolvedContextOptions resolveContextOptions(const Bindgen::NodeVMContextOptionsInput& input)
{
    if (input.is_defaulted())
        return { {}, JSC::jsUndefined() };

    RELEASE_ASSERT(input.is_options());
    const auto& source = input.options();
    return {
        resolveCodeGenerationOptions(source.code_generation),
        resolveDynamicImportOption(source.import_module_dynamically),
    };
}

template<typename Options>
inline RunningScriptOptions resolveRunningOptionsDictionary(const Options& source)
{
    RunningScriptOptions result;
    result.displayErrors = source.display_errors;
    result.timeout = source.timeout;
    result.breakOnSigint = source.break_on_sigint;
    return result;
}

inline RunningScriptOptions resolveRunningOptions(const Bindgen::NodeVMRunningScriptOptionsInput& input)
{
    if (input.is_defaulted())
        return {};
    RELEASE_ASSERT(input.is_options());
    return resolveRunningOptionsDictionary(input.options());
}

} // namespace Bun::NodeVM
