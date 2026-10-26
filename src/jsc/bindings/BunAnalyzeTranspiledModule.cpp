#include "root.h"
#include "SchemaBindings.h"

#include "JavaScriptCore/JSPromise.h"
#include "JavaScriptCore/JSModuleRecord.h"
#include "JavaScriptCore/GlobalObjectMethodTable.h"
#include "JavaScriptCore/Nodes.h"
#include "JavaScriptCore/Parser.h"
#include "JavaScriptCore/ParserError.h"
#include "JavaScriptCore/SyntheticModuleRecord.h"
#include <wtf/text/MakeString.h>
#include "JavaScriptCore/JSGlobalObject.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "ZigSourceProvider.h"
#include "ZigGlobalObject.h"
#include "IsolatedModuleCache.h"

// ref: JSModuleLoader.cpp
// ref: ModuleAnalyzer.cpp
// ref: JSModuleRecord.cpp
// ref: NodesAnalyzeModule.cpp, search ::analyzeModule

#include "JavaScriptCore/ModuleAnalyzer.h"
#include "JavaScriptCore/ErrorType.h"

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_compiler_module_records_compilerModuleRecordCreate(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_compiler_module_records_compilerModuleRecordCreate_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();

    WTF::Vector<JSC::Identifier> identifiers;
    identifiers.reserveInitialCapacity(args.identifiers.size());
    for (const auto& identifier : args.identifiers)
        identifiers.unsafeAppendWithoutCapacityCheck(JSC::Identifier::fromString(vm, identifier));

    auto identifierAt = [&](uint32_t index) -> JSC::Identifier {
        if (index == std::numeric_limits<uint32_t>::max())
            return vm.propertyNames->starDefaultPrivateName;
        if (index == std::numeric_limits<uint32_t>::max() - 1)
            return vm.propertyNames->starNamespacePrivateName;
        RELEASE_ASSERT(index < identifiers.size());
        return identifiers[index];
    };

    for (const auto& declaration : args.declarations) {
        using Kind = decltype(declaration.kind);
        switch (declaration.kind) {
        case Kind::Declared:
            args.declaredVariables->add(identifierAt(declaration.identifier));
            break;
        case Kind::Lexical:
            args.lexicalVariables->add(identifierAt(declaration.identifier));
            break;
        }
    }

    auto* moduleRecord = JSC::JSModuleRecord::create(
        globalObject,
        vm,
        globalObject->moduleRecordStructure(),
        *args.moduleKey,
        *args.sourceCode,
        *args.declaredVariables,
        *args.lexicalVariables,
        args.hasImportMeta ? JSC::ImportMetaFeature : 0);
    moduleRecord->m_isTypeScript = args.isTypeScript;
    moduleRecord->setHasTLA(args.hasTLA);

    for (const auto& requestedModule : args.requestedModules) {
        auto moduleName = identifierAt(requestedModule.moduleName);
        using Kind = decltype(requestedModule.kind);
        switch (requestedModule.kind) {
        case Kind::None: {
            RefPtr<JSC::ScriptFetchParameters> attributes;
            moduleRecord->appendRequestedModule(moduleName, std::move(attributes));
            break;
        }
        case Kind::JavaScript: {
            Ref<JSC::ScriptFetchParameters> attributes = JSC::ScriptFetchParameters::create(JSC::ScriptFetchParameters::Type::JavaScript);
            moduleRecord->appendRequestedModule(moduleName, std::move(attributes));
            break;
        }
        case Kind::WebAssembly: {
            Ref<JSC::ScriptFetchParameters> attributes = JSC::ScriptFetchParameters::create(JSC::ScriptFetchParameters::Type::WebAssembly);
            moduleRecord->appendRequestedModule(moduleName, std::move(attributes));
            break;
        }
        case Kind::JSON: {
            Ref<JSC::ScriptFetchParameters> attributes = JSC::ScriptFetchParameters::create(JSC::ScriptFetchParameters::Type::JSON);
            moduleRecord->appendRequestedModule(moduleName, std::move(attributes));
            break;
        }
        case Kind::HostDefined: {
            Ref<JSC::ScriptFetchParameters> attributes = JSC::ScriptFetchParameters::create(identifierAt(requestedModule.hostDefinedImportType).string());
            moduleRecord->appendRequestedModule(moduleName, std::move(attributes));
            break;
        }
        }
    }

    for (const auto& import : args.imports) {
        using Kind = decltype(import.kind);
        switch (import.kind) {
        case Kind::Single:
            moduleRecord->addImportEntry(JSC::JSModuleRecord::ImportEntry {
                .type = JSC::JSModuleRecord::ImportEntryType::Single,
                .moduleRequest = identifierAt(import.moduleName),
                .importName = identifierAt(import.importName),
                .localName = identifierAt(import.localName),
            });
            break;
        case Kind::SingleTypeScript:
            moduleRecord->addImportEntry(JSC::JSModuleRecord::ImportEntry {
                .type = JSC::JSModuleRecord::ImportEntryType::SingleTypeScript,
                .moduleRequest = identifierAt(import.moduleName),
                .importName = identifierAt(import.importName),
                .localName = identifierAt(import.localName),
            });
            break;
        case Kind::Namespace:
            moduleRecord->addImportEntry(JSC::JSModuleRecord::ImportEntry {
                .type = JSC::JSModuleRecord::ImportEntryType::Namespace,
                .moduleRequest = identifierAt(import.moduleName),
                .importName = identifierAt(import.importName),
                .localName = identifierAt(import.localName),
            });
            break;
        }
    }

    for (const auto& exportEntry : args.exports) {
        using Kind = decltype(exportEntry.kind);
        switch (exportEntry.kind) {
        case Kind::Indirect:
            moduleRecord->addExportEntry(JSC::JSModuleRecord::ExportEntry::createIndirect(
                identifierAt(exportEntry.exportName),
                identifierAt(exportEntry.importName),
                identifierAt(exportEntry.moduleName)));
            break;
        case Kind::Local:
            moduleRecord->addExportEntry(JSC::JSModuleRecord::ExportEntry::createLocal(
                identifierAt(exportEntry.exportName),
                identifierAt(exportEntry.localName)));
            break;
        case Kind::Namespace:
            moduleRecord->addExportEntry(JSC::JSModuleRecord::ExportEntry::createNamespace(
                identifierAt(exportEntry.exportName),
                identifierAt(exportEntry.moduleName)));
            break;
        case Kind::Star:
            moduleRecord->addStarExportEntry(identifierAt(exportEntry.moduleName));
            break;
        }
    }

    return JSC::JSValue(moduleRecord);
}

namespace Zig {
using namespace JSC;

static String dumpRecordInfo(JSModuleRecord* moduleRecord);

static JSPromise* fallbackParse(JSGlobalObject* globalObject, const Identifier& moduleKey, const SourceCode& sourceCode, JSPromise* promise, JSModuleRecord* resultValue = nullptr);
JSPromise* GlobalObject::moduleLoaderAnalyzeTranspiledModule(JSGlobalObject* globalObject, const Identifier& moduleKey, const SourceCode& sourceCode, JSPromise* promise)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto rejectWithError = [&](JSValue error) {
        promise->reject(vm, error);
        return promise;
    };

    VariableEnvironment declaredVariables = VariableEnvironment();
    VariableEnvironment lexicalVariables = VariableEnvironment();

    auto provider = static_cast<Zig::SourceProvider*>(sourceCode.provider());

    if (!provider->m_resolvedSource.moduleInfo) {
        dataLog("[note] module_info is null for module: ", moduleKey.utf8(), "\n");
        RELEASE_AND_RETURN(scope, rejectWithError(createError(globalObject, WTF::String::fromLatin1("module_info is null"))));
    }

    auto* moduleInfo = *provider->m_resolvedSource.moduleInfo;
    auto moduleRecordValue = Bun::Bindgen::ZigExports::bunBindgenZig_compiler_module_records_compilerArtifactToModuleRecord(
        globalObject,
        &moduleKey,
        &sourceCode,
        &declaredVariables,
        &lexicalVariables,
        moduleInfo);
    auto* moduleRecord = moduleRecordValue ? dynamicDowncast<JSC::JSModuleRecord>(*moduleRecordValue) : nullptr;
    // Under --isolate the same SourceProvider is reused across globals via the
    // IsolatedModuleCache, so module_info must remain alive on the provider;
    // ~SourceProvider frees it. Otherwise, free now.
    if (!Bun::IsolatedModuleCache::canUse(vm, defaultGlobalObject(globalObject)->bunVM())) {
        Bun::Bindgen::Engine::releaseModuleInfoDeserialized(moduleInfo);
        provider->m_resolvedSource.moduleInfo.reset();
    }
    RETURN_IF_EXCEPTION(scope, promise->rejectWithCaughtException(vm, scope));
    if (moduleRecord == nullptr) {
        RELEASE_AND_RETURN(scope, rejectWithError(createError(globalObject, WTF::String::fromLatin1("parseFromSourceCode failed"))));
    }

#if BUN_DEBUG
    RELEASE_AND_RETURN(scope, fallbackParse(globalObject, moduleKey, sourceCode, promise, moduleRecord));
#else
    promise->resolve(globalObject, vm, moduleRecord);
    RELEASE_AND_RETURN(scope, promise);
#endif
}
static JSPromise* fallbackParse(JSGlobalObject* globalObject, const Identifier& moduleKey, const SourceCode& sourceCode, JSPromise* promise, JSModuleRecord* resultValue)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto rejectWithError = [&](JSValue error) {
        promise->reject(vm, error);
        return promise;
    };

    ParserError error;
    std::unique_ptr<ModuleProgramNode> moduleProgramNode = parseRootNode<ModuleProgramNode>(
        vm, sourceCode, ImplementationVisibility::Public, JSParserBuiltinMode::NotBuiltin,
        StrictModeLexicallyScopedFeature, JSParserScriptMode::Module, SourceParseMode::ModuleAnalyzeMode, error);
    if (error.isValid())
        RELEASE_AND_RETURN(scope, rejectWithError(error.toErrorObject(globalObject, sourceCode)));
    ASSERT(moduleProgramNode);

    ModuleAnalyzer moduleAnalyzer(globalObject, moduleKey, sourceCode, moduleProgramNode->varDeclarations(), moduleProgramNode->lexicalVariables(), moduleProgramNode->features());
    RETURN_IF_EXCEPTION(scope, promise->rejectWithCaughtException(vm, scope));

    auto result = moduleAnalyzer.analyze(*moduleProgramNode);
    if (!result) {
        auto [errorType, message] = std::move(result.error());
        RELEASE_AND_RETURN(scope, rejectWithError(createError(globalObject, errorType, message)));
    }

    JSModuleRecord* moduleRecord = result.value();

    if (resultValue != nullptr) {
        auto actual = dumpRecordInfo(resultValue);
        auto expected = dumpRecordInfo(moduleRecord);
        if (actual != expected) {
            dataLog("\n\n\n\n\n\n\x1b[95mBEGIN analyzeTranspiledModule\x1b(B\x1b[m\n  --- module key ---\n", moduleKey.utf8().data(), "\n  --- code ---\n\n", sourceCode.toUTF8().data(), "\n");
            dataLog("  ------", "\n");
            dataLog("  BunAnalyzeTranspiledModule:", "\n");

            Bun::Bindgen::ZigExports::bunBindgenZig_compiler_module_records_compilerRenderDiff(globalObject, expected, actual);
            RETURN_IF_EXCEPTION(scope, nullptr);

            RELEASE_AND_RETURN(scope, rejectWithError(createError(globalObject, WTF::String::fromLatin1("Imports different between parseFromSourceCode and fallbackParse"))));
        }
    }

    scope.release();
    promise->resolve(globalObject, vm, resultValue == nullptr ? moduleRecord : resultValue);
    return promise;
}

String dumpRecordInfo(JSModuleRecord* moduleRecord)
{
    WTF::StringPrintStream stream;

    {
        Vector<String> sortedVars;
        for (const auto& pair : moduleRecord->declaredVariables())
            sortedVars.append(String(pair.key.get()));
        std::sort(sortedVars.begin(), sortedVars.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        stream.print("  varDeclarations:\n");
        for (const auto& name : sortedVars)
            stream.print("  - ", name, "\n");
    }

    {
        Vector<String> sortedVars;
        for (const auto& pair : moduleRecord->lexicalVariables())
            sortedVars.append(String(pair.key.get()));
        std::sort(sortedVars.begin(), sortedVars.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        stream.print("  lexicalVariables:\n");
        for (const auto& name : sortedVars)
            stream.print("  - ", name, "\n");
    }

    stream.print("  features: (not accessible)\n");

    stream.print("\nAnalyzing ModuleRecord key(", moduleRecord->moduleKey().impl(), ")\n");

    stream.print("    Dependencies: ", moduleRecord->requestedModules().size(), " modules\n");
    {
        Vector<String> sortedDeps;
        for (const auto& request : moduleRecord->requestedModules()) {
            WTF::StringPrintStream line;
            if (request.m_attributes == nullptr)
                line.print("      module(", request.m_specifier, ")\n");
            else
                line.print("      module(", request.m_specifier, "),attributes(", (uint8_t)request.m_attributes->type(), ", ", request.m_attributes->hostDefinedImportType(), ")\n");
            sortedDeps.append(line.toString());
        }
        std::sort(sortedDeps.begin(), sortedDeps.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        for (const auto& dep : sortedDeps)
            stream.print(dep);
    }

    stream.print("    Import: ", moduleRecord->importEntries().size(), " entries\n");
    {
        Vector<String> sortedImports;
        for (const auto& pair : moduleRecord->importEntries()) {
            WTF::StringPrintStream line;
            auto& importEntry = pair.value;
            line.print("      import(", importEntry.importName, "), local(", importEntry.localName, "), module(", importEntry.moduleRequest, ")\n");
            sortedImports.append(line.toString());
        }
        std::sort(sortedImports.begin(), sortedImports.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        for (const auto& imp : sortedImports)
            stream.print(imp);
    }

    stream.print("    Export: ", moduleRecord->exportEntries().size(), " entries\n");
    Vector<String> sortedEntries;
    for (const auto& pair : moduleRecord->exportEntries()) {
        WTF::StringPrintStream line;
        auto& exportEntry = pair.value;
        switch (exportEntry.type) {
        case AbstractModuleRecord::ExportEntry::Type::Local:
            line.print("      [Local] ", "export(", exportEntry.exportName, "), local(", exportEntry.localName, ")\n");
            break;

        case AbstractModuleRecord::ExportEntry::Type::Indirect:
            line.print("      [Indirect] ", "export(", exportEntry.exportName, "), import(", exportEntry.importName, "), module(", exportEntry.moduleName, ")\n");
            break;

        case AbstractModuleRecord::ExportEntry::Type::Namespace:
            line.print("      [Namespace] ", "export(", exportEntry.exportName, "), module(", exportEntry.moduleName, ")\n");
            break;
        }
        sortedEntries.append(line.toString());
    }
    std::sort(sortedEntries.begin(), sortedEntries.end(), [](const String& a, const String& b) {
        return codePointCompare(a, b) < 0;
    });
    for (const auto& entry : sortedEntries)
        stream.print(entry);

    {
        Vector<String> sortedStarExports;
        for (const auto& moduleName : moduleRecord->starExportEntries()) {
            WTF::StringPrintStream line;
            line.print("      [Star] module(", moduleName.get(), ")\n");
            sortedStarExports.append(line.toString());
        }
        std::sort(sortedStarExports.begin(), sortedStarExports.end(), [](const String& a, const String& b) {
            return codePointCompare(a, b) < 0;
        });
        for (const auto& entry : sortedStarExports)
            stream.print(entry);
    }

    stream.print("  -> done\n");

    return stream.toString();
}

} // namespace Zig
