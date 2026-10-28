#include "root.h"
#include "SchemaBindings.h"

#include "JavaScriptCore/PropertySlot.h"
#include "JavaScriptCore/ExecutableInfo.h"
#include "JavaScriptCore/WriteBarrierInlines.h"
#include "ErrorCode.h"
#include <JavaScriptCore/SourceOrigin.h>
#include <JavaScriptCore/SourceProvider.h>

#include "BunClientData.h"
#include "NodeVM.h"
#include "NodeVMScript.h"
#include "NodeVMBindingOptions.h"
#include "NodeVMModule.h"
#include "NodeVMSourceTextModule.h"
#include "NodeVMSyntheticModule.h"

#include "JavaScriptCore/JSObjectInlines.h"
#include "JavaScriptCore/JSModuleRecord.h"
#include "wtf/text/ExternalStringImpl.h"

#include "JavaScriptCore/FunctionPrototype.h"
#include "JavaScriptCore/FunctionConstructor.h"
#include "JavaScriptCore/HeapAnalyzer.h"

#include "JavaScriptCore/JSDestructibleObjectHeapCellType.h"
#include "JavaScriptCore/SlotVisitorMacros.h"
#include "JavaScriptCore/ObjectConstructor.h"
#include "JavaScriptCore/SubspaceInlines.h"
#include "wtf/GetPtr.h"
#include "wtf/PointerPreparations.h"
#include "wtf/URL.h"
#include "JavaScriptCore/TypedArrayInlines.h"
#include "JavaScriptCore/PropertyNameArray.h"
#include "JavaScriptCore/JSWeakMap.h"
#include "JavaScriptCore/JSWeakMapInlines.h"
#include "JavaScriptCore/JSWithScope.h"
#include "JavaScriptCore/JSGlobalProxyInlines.h"
#include "GCDefferalContext.h"
#include "JSBuffer.h"

#include <JavaScriptCore/Completion.h>
#include "JavaScriptCore/LazyClassStructureInlines.h"
#include "JavaScriptCore/Parser.h"
#include "JavaScriptCore/SourceCodeKey.h"
#include "JavaScriptCore/UnlinkedFunctionExecutable.h"
#include "AsyncContextFrame.h"
#include "JavaScriptCore/JSCInlines.h"
#include "JavaScriptCore/JSPromise.h"
#include "JavaScriptCore/BytecodeCacheError.h"
#include "JavaScriptCore/CodeCache.h"
#include "JavaScriptCore/FunctionCodeBlock.h"
#include "JavaScriptCore/JIT.h"
#include "JavaScriptCore/ProgramCodeBlock.h"
#include "JavaScriptCore/GlobalObjectMethodTable.h"
#include "NodeVMScriptFetcher.h"
#include "wtf/FileHandle.h"

#include "../vm/SigintWatcher.h"

#include "JavaScriptCore/GetterSetter.h"

namespace Bun {
using namespace WebCore;

static JSPromise* moduleLoaderImportModuleInner(NodeVMGlobalObject* globalObject, JSC::JSModuleLoader* moduleLoader, JSC::JSString* moduleName, RefPtr<JSC::ScriptFetchParameters> parameters, const JSC::SourceOrigin& sourceOrigin);

namespace NodeVM {

static JSPromise* importModuleInner(JSGlobalObject* globalObject, JSString* moduleName, RefPtr<JSC::ScriptFetchParameters> parameters, const SourceOrigin& sourceOrigin, JSValue dynamicImportCallback, JSValue owner);

static JSValue scriptFetchParametersToImportAttributes(JSGlobalObject* globalObject, JSC::ScriptFetchParameters* params)
{
    auto& vm = globalObject->vm();
    auto* obj = constructEmptyObject(vm, globalObject->nullPrototypeObjectStructure());
    if (!params)
        return obj;
    if (!params->attributes().isEmpty()) {
        for (auto& [key, value] : params->attributes())
            obj->putDirect(vm, JSC::Identifier::fromUid(vm, key.get()), jsString(vm, value));
        return obj;
    }
    switch (params->type()) {
    case JSC::ScriptFetchParameters::Type::JSON:
        obj->putDirect(vm, vm.propertyNames->type, jsNontrivialString(vm, "json"_s));
        break;
    case JSC::ScriptFetchParameters::Type::Text:
        obj->putDirect(vm, vm.propertyNames->type, jsNontrivialString(vm, "text"_s));
        break;
    case JSC::ScriptFetchParameters::Type::WebAssembly:
        obj->putDirect(vm, vm.propertyNames->type, jsNontrivialString(vm, "webassembly"_s));
        break;
    case JSC::ScriptFetchParameters::Type::JavaScript:
        obj->putDirect(vm, vm.propertyNames->type, jsNontrivialString(vm, "javascript"_s));
        break;
    case JSC::ScriptFetchParameters::Type::HostDefined:
        obj->putDirect(vm, vm.propertyNames->type, jsString(vm, params->hostDefinedImportType()));
        break;
    case JSC::ScriptFetchParameters::Type::None:
        break;
    }
    return obj;
}

JSC::JSFunction* constructAnonymousFunction(JSC::JSGlobalObject* globalObject, const ArgList& args, const SourceOrigin& sourceOrigin, CompileFunctionOptions&& options, JSC::SourceTaintedOrigin sourceTaintOrigin, JSC::JSScope* scope)
{
    ASSERT(scope);

    VM& vm = globalObject->vm();
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    TextPosition position(options.lineOffset, options.columnOffset);
    LexicallyScopedFeatures lexicallyScopedFeatures = globalObject->globalScopeExtension() ? TaintedByWithScopeLexicallyScopedFeature : NoLexicallyScopedFeatures;

    // First try parsing the code as is without wrapping it in an anonymous function expression.
    // This is to reject cases where the user passes in a string like "});(function() {".
    if (!args.isEmpty() && args.at(0).isString()) {
        ParserError error;
        String code = args.at(0).toWTFString(globalObject);

        SourceCode sourceCode(
            JSC::StringSourceProvider::create(code, sourceOrigin, options.filename, sourceTaintOrigin, position, SourceProviderSourceType::Program),
            position.m_line.oneBasedInt(), position.m_column.oneBasedInt());

        if (!checkSyntax(vm, sourceCode, error)) {
            ASSERT(error.isValid());

            bool actuallyValid = true;

            if (error.type() == ParserError::ErrorType::SyntaxError && error.syntaxErrorType() == ParserError::SyntaxErrorIrrecoverable) {
                String message = error.message();
                if (message == "Return statements are only valid inside functions.") {
                    actuallyValid = false;
                } else {
                    const JSToken& token = error.token();
                    int start = token.m_startPosition.offset;
                    int end = token.m_endPosition.offset;
                    if (start >= 0 && start < end) {
                        StringView tokenView = sourceCode.view().substring(start, end - start);
                        error = ParserError(ParserError::SyntaxError, ParserError::SyntaxErrorIrrecoverable, token, makeString("Unexpected token '"_s, tokenView, '\''), error.line());
                    }
                }
            }

            if (actuallyValid) {
                auto exception = error.toErrorObject(globalObject, sourceCode, -1);
                RETURN_IF_EXCEPTION(throwScope, nullptr);
                throwException(globalObject, throwScope, exception);
                return nullptr;
            }
        }
    }

    // wrap the arguments in an anonymous function expression
    int startOffset = 0;
    String code = stringifyAnonymousFunction(globalObject, args, throwScope, &startOffset);
    EXCEPTION_ASSERT(!!throwScope.exception() == code.isNull());

    SourceCode sourceCode(
        JSC::StringSourceProvider::create(code, sourceOrigin, WTF::move(options.filename), sourceTaintOrigin, position, SourceProviderSourceType::Program),
        position.m_line.oneBasedInt(), position.m_column.oneBasedInt());

    CodeCache* cache = vm.codeCache();
    ProgramExecutable* programExecutable = ProgramExecutable::create(globalObject, sourceCode);

    UnlinkedProgramCodeBlock* unlinkedProgramCodeBlock = nullptr;
    RefPtr<CachedBytecode> cachedBytecode;

    TriState bytecodeAccepted = TriState::Indeterminate;

    if (!options.cachedData.isEmpty()) {
        cachedBytecode = CachedBytecode::create(std::span(options.cachedData), nullptr, {});
        SourceCodeKey key(sourceCode, {}, JSC::SourceCodeType::ProgramType, lexicallyScopedFeatures, JSC::JSParserScriptMode::Classic, JSC::DerivedContextType::None, JSC::EvalContextType::None, false, {}, std::nullopt);
        unlinkedProgramCodeBlock = JSC::decodeCodeBlock<UnlinkedProgramCodeBlock>(vm, key, *cachedBytecode);
        if (unlinkedProgramCodeBlock == nullptr) {
            bytecodeAccepted = TriState::False;
        } else {
            bytecodeAccepted = TriState::True;
        }
    }

    ParserError error;

    if (unlinkedProgramCodeBlock == nullptr) {
        unlinkedProgramCodeBlock = cache->getUnlinkedProgramCodeBlock(vm, programExecutable, sourceCode, {}, error);
    }

    if (!unlinkedProgramCodeBlock || error.isValid()) {
        return nullptr;
    }

    ProgramCodeBlock* programCodeBlock = nullptr;
    {
        DeferGC deferGC(vm);
        programCodeBlock = ProgramCodeBlock::create(vm, programExecutable, unlinkedProgramCodeBlock, scope);
        RETURN_IF_EXCEPTION(throwScope, nullptr);
    }

    if (!programCodeBlock || programCodeBlock->numberOfFunctionExprs() == 0) {
        return nullptr;
    }

    FunctionExecutable* functionExecutable = programCodeBlock->functionExpr(0);
    if (!functionExecutable) {
        return nullptr;
    }

    Structure* structure = JSFunction::selectStructureForNewFuncExp(globalObject, functionExecutable);
    JSFunction* function = JSFunction::create(vm, globalObject, functionExecutable, scope, structure);

    if (bytecodeAccepted == TriState::Indeterminate) {
        if (options.produceCachedData) {
            RefPtr<JSC::CachedBytecode> producedBytecode = getBytecode(globalObject, programExecutable, sourceCode);
            if (producedBytecode) {
                JSC::JSUint8Array* buffer = WebCore::createBuffer(globalObject, producedBytecode->span());
                RETURN_IF_EXCEPTION(throwScope, nullptr);
                function->putDirect(vm, JSC::Identifier::fromString(vm, "cachedData"_s), buffer);
                function->putDirect(vm, JSC::Identifier::fromString(vm, "cachedDataProduced"_s), jsBoolean(true));
            } else {
                function->putDirect(vm, JSC::Identifier::fromString(vm, "cachedDataProduced"_s), jsBoolean(false));
            }
        }
    } else {
        function->putDirect(vm, JSC::Identifier::fromString(vm, "cachedDataRejected"_s), jsBoolean(bytecodeAccepted == TriState::False));
        RETURN_IF_EXCEPTION(throwScope, nullptr);
    }

    return function;
}

JSPromise* importModule(JSGlobalObject* globalObject, JSString* moduleName, RefPtr<JSC::ScriptFetchParameters> parameters, const SourceOrigin& sourceOrigin)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (auto* fetcher = sourceOrigin.fetcher(); !fetcher || fetcher->fetcherType() != ScriptFetcher::Type::NodeVM) {
        if (!sourceOrigin.url().isEmpty()) {
            if (auto* nodeVmGlobalObject = dynamicDowncast<NodeVMGlobalObject>(globalObject)) {
                if (nodeVmGlobalObject->dynamicImportCallback()) {
                    RELEASE_AND_RETURN(scope, moduleLoaderImportModuleInner(nodeVmGlobalObject, globalObject->moduleLoader(), moduleName, WTF::move(parameters), sourceOrigin));
                }
            }
        }
        return nullptr;
    }

    auto* fetcher = static_cast<NodeVMScriptFetcher*>(sourceOrigin.fetcher());

    if (fetcher->isUsingDefaultLoader()) {
        return nullptr;
    }

    JSValue dynamicImportCallback = fetcher->dynamicImportCallback();

    if (isUseMainContextDefaultLoaderConstant(globalObject, dynamicImportCallback)) {
        auto defer = fetcher->temporarilyUseDefaultLoader();
        Zig::GlobalObject* zigGlobalObject = defaultGlobalObject(globalObject);
        RELEASE_AND_RETURN(scope, zigGlobalObject->moduleLoaderImportModule(zigGlobalObject, zigGlobalObject->moduleLoader(), moduleName, WTF::move(parameters), sourceOrigin, /* deferred */ false));
    } else if (!dynamicImportCallback || !dynamicImportCallback.isCallable()) {
        throwException(globalObject, scope, createError(globalObject, ErrorCode::ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING, "A dynamic import callback was not specified."_s));
        return nullptr;
    }

    RELEASE_AND_RETURN(scope, importModuleInner(globalObject, moduleName, WTF::move(parameters), sourceOrigin, dynamicImportCallback, fetcher->owner()));
}

static JSPromise* importModuleInner(JSGlobalObject* globalObject, JSString* moduleName, RefPtr<JSC::ScriptFetchParameters> parameters, const SourceOrigin& sourceOrigin, JSValue dynamicImportCallback, JSValue owner)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSValue importAttributes = scriptFetchParametersToImportAttributes(globalObject, parameters.get());
    RETURN_IF_EXCEPTION(scope, nullptr);

    MarkedArgumentBuffer args;
    args.append(moduleName);
    if (owner) {
        args.append(owner);
    } else if (auto* nodeVmGlobalObject = dynamicDowncast<NodeVMGlobalObject>(globalObject)) {
        if (nodeVmGlobalObject->isNotContextified()) {
            args.append(nodeVmGlobalObject->specialSandbox());
        } else {
            args.append(nodeVmGlobalObject->contextifiedObject());
        }
    } else {
        args.append(jsUndefined());
    }
    args.append(importAttributes);
    args.append(jsNontrivialString(vm, "evaluation"_s));
    if (args.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return nullptr;
    }

    JSValue result = AsyncContextFrame::call(globalObject, dynamicImportCallback, jsUndefined(), args);

    RETURN_IF_EXCEPTION(scope, nullptr);

    if (result.isUndefinedOrNull()) {
        throwException(globalObject, scope, createError(globalObject, ErrorCode::ERR_VM_MODULE_NOT_MODULE, "Provided module is not an instance of Module"_s));
        return nullptr;
    }

    if (auto* promise = dynamicDowncast<JSPromise>(result)) {
        return promise;
    }

    auto* promise = JSPromise::create(vm, globalObject->promiseStructure());

    RETURN_IF_EXCEPTION(scope, nullptr);

    auto* transformer = JSFunction::create(
        vm,
        globalObject,
        1,
        String(),
        bun_bindgen_host_NodeVM_moduleNamespaceOrOriginal,
        ImplementationVisibility::Private);

    RETURN_IF_EXCEPTION(scope, nullptr);

    promise->fulfill(vm, result);
    RETURN_IF_EXCEPTION(scope, nullptr);

    JSObject* thenResult = promise->then(globalObject, transformer, jsUndefined());
    RETURN_IF_EXCEPTION(scope, nullptr);

    // JSPromise::then() may return a non-JSPromise when Promise[Symbol.species]
    // is overridden in the vm context — don't uncheckedDowncast (release-mode
    // static_cast) on a user-influenced shape.
    if (auto* thenPromise = dynamicDowncast<JSPromise>(thenResult))
        RELEASE_AND_RETURN(scope, thenPromise);
    RELEASE_AND_RETURN(scope, JSPromise::resolvedPromise(globalObject, thenResult));
}

// Helper function to create an anonymous function expression with parameters
String stringifyAnonymousFunction(JSGlobalObject* globalObject, const ArgList& args, ThrowScope& scope, int* outOffset)
{
    // How we stringify functions is important for creating anonymous function expressions
    String program;
    if (args.isEmpty()) {
        // No arguments, just an empty function body
        program = "(function () {\n\n})"_s;
    } else if (args.size() == 1) {
        // Just the function body
        auto body = args.at(0).toWTFString(globalObject);
        RETURN_IF_EXCEPTION(scope, {});

        program = tryMakeString("(function () {\n"_s, body, "\n})"_s);
        *outOffset = "(function () {\n"_s.length();

        if (!program) [[unlikely]] {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
    } else {
        // Process parameters and body
        unsigned parameterCount = args.size() - 1;
        StringBuilder paramString;

        for (unsigned i = 0; i < parameterCount; ++i) {
            auto param = args.at(i).toWTFString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});

            if (i > 0) {
                paramString.append(", "_s);
            }

            paramString.append(param);
        }

        auto body = args.at(parameterCount).toWTFString(globalObject);
        RETURN_IF_EXCEPTION(scope, {});

        program = tryMakeString("(function ("_s, paramString.toString(), ") {\n"_s, body, "\n})"_s);
        *outOffset = "(function ("_s.length() + paramString.length() + ") {\n"_s.length();

        if (!program) [[unlikely]] {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
    }

    return program;
}

RefPtr<JSC::CachedBytecode> getBytecode(JSGlobalObject* globalObject, JSC::ProgramExecutable* executable, const JSC::SourceCode& source)
{
    VM& vm = JSC::getVM(globalObject);
    JSC::CodeCache* cache = vm.codeCache();
    JSC::ParserError parserError;
    JSC::UnlinkedProgramCodeBlock* unlinked = cache->getUnlinkedProgramCodeBlock(vm, executable, source, {}, parserError);
    if (!unlinked || parserError.isValid()) {
        return nullptr;
    }
    JSC::LexicallyScopedFeatures lexicallyScopedFeatures = globalObject->globalScopeExtension() ? TaintedByWithScopeLexicallyScopedFeature : NoLexicallyScopedFeatures;
    JSC::BytecodeCacheError bytecodeCacheError;
    FileSystem::FileHandle fileHandle;
    return JSC::serializeBytecode(vm, unlinked, source, JSC::SourceCodeType::ProgramType, lexicallyScopedFeatures, JSParserScriptMode::Classic, fileHandle, bytecodeCacheError, {});
}

RefPtr<JSC::CachedBytecode> getBytecode(JSGlobalObject* globalObject, JSC::ModuleProgramExecutable* executable, const JSC::SourceCode& source)
{
    VM& vm = JSC::getVM(globalObject);
    JSC::CodeCache* cache = vm.codeCache();
    JSC::ParserError parserError;
    JSC::UnlinkedModuleProgramCodeBlock* unlinked = cache->getUnlinkedModuleProgramCodeBlock(vm, executable, source, {}, parserError);
    if (!unlinked || parserError.isValid()) {
        return nullptr;
    }
    JSC::LexicallyScopedFeatures lexicallyScopedFeatures = globalObject->globalScopeExtension() ? TaintedByWithScopeLexicallyScopedFeature : NoLexicallyScopedFeatures;
    JSC::BytecodeCacheError bytecodeCacheError;
    FileSystem::FileHandle fileHandle;
    return JSC::serializeBytecode(vm, unlinked, source, JSC::SourceCodeType::ProgramType, lexicallyScopedFeatures, JSParserScriptMode::Classic, fileHandle, bytecodeCacheError, {});
}

JSC::EncodedJSValue createCachedData(JSGlobalObject* globalObject, const JSC::SourceCode& source)
{
    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSC::ProgramExecutable* executable = JSC::ProgramExecutable::create(globalObject, source);
    RETURN_IF_EXCEPTION(scope, {});

    RefPtr<JSC::CachedBytecode> bytecode = getBytecode(globalObject, executable, source);
    RETURN_IF_EXCEPTION(scope, {});

    if (!bytecode) [[unlikely]] {
        return throwVMError(globalObject, scope, "createCachedData failed"_s);
    }

    std::span<const uint8_t> bytes = bytecode->span();
    JSC::JSUint8Array* buffer = WebCore::createBuffer(globalObject, bytes);
    RETURN_IF_EXCEPTION(scope, {});

    if (!buffer) {
        return throwVMError(globalObject, scope, "Failed to create buffer"_s);
    }

    return JSValue::encode(buffer);
}

bool handleException(JSGlobalObject* globalObject, VM& vm, NakedPtr<JSC::Exception> exception, ThrowScope& throwScope, bool displayErrors)
{
    if (!displayErrors)
        return false;

    if (auto* errorInstance = dynamicDowncast<ErrorInstance>(exception->value())) {
        errorInstance->materializeErrorInfoIfNeeded(vm, vm.propertyNames->stack);
        RETURN_IF_EXCEPTION(throwScope, {});
        JSValue stack_jsval = errorInstance->get(globalObject, vm.propertyNames->stack);
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!stack_jsval.isString()) {
            return false;
        }
        String stack = stack_jsval.toWTFString(globalObject);
        RETURN_IF_EXCEPTION(throwScope, {});

        auto& e_stack = exception->stack();
        size_t stack_size = e_stack.size();
        if (stack_size == 0) {
            return false;
        }
        auto& stack_frame = e_stack[0];
        auto source_url = stack_frame.sourceURL(vm);
        // Treat empty, [unknown], and [source:*] placeholders as missing source URLs
        if (source_url.isEmpty() || source_url == "[unknown]"_s || source_url.startsWith("[source:"_s)) {
            // copy what Node does: https://github.com/nodejs/node/blob/afe3909483a2d5ae6b847055f544da40571fb28d/lib/vm.js#L94
            source_url = "evalmachine.<anonymous>"_s;
        }
        auto line_and_column = stack_frame.computeLineAndColumn();

        String prepend = makeString(source_url, ":"_s, line_and_column.line, "\n"_s, stack);
        errorInstance->putDirect(vm, vm.propertyNames->stack, jsString(vm, prepend), JSC::PropertyAttribute::DontEnum | 0);

        JSC::throwException(globalObject, throwScope, exception.get());
        return true;
    }
    return false;
}

NodeVMGlobalObject* getGlobalObjectFromContext(JSGlobalObject* globalObject, JSValue contextValue, bool canThrow)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());

    if (contextValue.isUndefinedOrNull()) {
        if (canThrow) {
            ERR::INVALID_ARG_TYPE(scope, globalObject, "context"_s, "object"_s, contextValue);
        }
        return nullptr;
    }

    if (!contextValue.isObject()) {
        if (canThrow) {
            ERR::INVALID_ARG_TYPE(scope, globalObject, "context"_s, "object"_s, contextValue);
        }
        return nullptr;
    }

    JSObject* context = asObject(contextValue);
    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    JSValue scopeValue = zigGlobalObject->vmModuleContextMap()->get(context);
    if (scopeValue.isUndefined()) {
        if (auto* specialSandbox = dynamicDowncast<NodeVMSpecialSandbox>(context)) {
            return specialSandbox->parentGlobal();
        }

        if (auto* proxy = dynamicDowncast<JSGlobalProxy>(context)) {
            if (auto* nodeVmGlobalObject = dynamicDowncast<NodeVMGlobalObject>(proxy->target())) {
                return nodeVmGlobalObject;
            }
        }

        if (canThrow) {
            INVALID_ARG_VALUE_VM_VARIATION(scope, globalObject, "contextifiedObject"_s, context);
        }
        return nullptr;
    }

    auto* nodeVmGlobalObject = dynamicDowncast<NodeVMGlobalObject>(scopeValue);

    if (!nodeVmGlobalObject) {
        nodeVmGlobalObject = dynamicDowncast<NodeVMGlobalObject>(context);
    }

    if (!nodeVmGlobalObject) {
        if (canThrow) {
            INVALID_ARG_VALUE_VM_VARIATION(scope, globalObject, "contextifiedObject"_s, context);
        }
        return nullptr;
    }

    return nodeVmGlobalObject;
}

/// For some reason Node has this error message with a grammatical error and we have to match it so the tests pass:
/// `The "<name>" argument must be an vm.Context`
JSC::EncodedJSValue INVALID_ARG_VALUE_VM_VARIATION(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral name, JSC::JSValue value)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, makeString("The \""_s, name, "\" argument must be an vm.Context"_s)));
    throwScope.release();
    return {};
}

bool isContext(JSGlobalObject* globalObject, JSValue value)
{
    auto* zigGlobalObject = defaultGlobalObject(globalObject);

    if (zigGlobalObject->vmModuleContextMap()->has(asObject(value))) {
        return true;
    }

    if (value.inherits(NodeVMSpecialSandbox::info())) {
        return true;
    }

    if (auto* proxy = dynamicDowncast<JSGlobalProxy>(value); proxy && proxy->target()) {
        return proxy->target()->inherits(NodeVMGlobalObject::info());
    }

    return false;
}

bool isDontContextifyConstant(JSGlobalObject* globalObject, JSValue value)
{
    if (value.isSymbol()) {
        Zig::GlobalObject* zigGlobalObject = defaultGlobalObject(globalObject);
        return value == zigGlobalObject->m_nodeVMDontContextify.get(zigGlobalObject);
    }
    return false;
}

bool isUseMainContextDefaultLoaderConstant(JSGlobalObject* globalObject, JSValue value)
{
    if (value.isSymbol()) {
        Zig::GlobalObject* zigGlobalObject = defaultGlobalObject(globalObject);
        if (value == zigGlobalObject->m_nodeVMUseMainContextDefaultLoader.get(zigGlobalObject)) {
            return true;
        }
    }

    return false;
}

namespace TypePredicates {

bool isScript(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::NodeVMScript>(value);
}

bool isContext(JSC::JSGlobalObject& globalObject, JSC::JSValue value) noexcept
{
    return value.isObject() && Bun::NodeVM::isContext(&globalObject, value);
}

bool isDontContextifyConstant(JSC::JSGlobalObject& globalObject, JSC::JSValue value) noexcept
{
    return Bun::NodeVM::isDontContextifyConstant(&globalObject, value);
}

bool isUseMainContextDefaultLoaderConstant(JSC::JSGlobalObject& globalObject, JSC::JSValue value) noexcept
{
    return Bun::NodeVM::isUseMainContextDefaultLoaderConstant(&globalObject, value);
}

bool isModule(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::NodeVMModule>(value);
}

bool isSourceTextModule(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::NodeVMSourceTextModule>(value);
}

bool isSyntheticModule(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::NodeVMSyntheticModule>(value);
}

bool isScriptConstructor(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::NodeVMScriptConstructor>(value);
}

bool isModuleConstructor(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::NodeVMModuleConstructor>(value);
}

}

} // namespace NodeVM

using namespace NodeVM;

template<typename, JSC::SubspaceAccess mode> JSC::GCClient::IsoSubspace* NodeVMSpecialSandbox::subspaceFor(JSC::VM& vm)
{
    if constexpr (mode == JSC::SubspaceAccess::Concurrently)
        return nullptr;
    return WebCore::subspaceForImpl<NodeVMSpecialSandbox, WebCore::UseCustomHeapCellType::No>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForNodeVMSpecialSandbox.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForNodeVMSpecialSandbox = std::forward<decltype(space)>(space); },
        [](auto& spaces) { return spaces.m_subspaceForNodeVMSpecialSandbox.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForNodeVMSpecialSandbox = std::forward<decltype(space)>(space); });
}

NodeVMSpecialSandbox* NodeVMSpecialSandbox::create(VM& vm, Structure* structure, NodeVMGlobalObject* globalObject)
{
    NodeVMSpecialSandbox* ptr = new (NotNull, allocateCell<NodeVMSpecialSandbox>(vm)) NodeVMSpecialSandbox(vm, structure, globalObject);
    ptr->finishCreation(vm);
    return ptr;
}

JSC::Structure* NodeVMSpecialSandbox::createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
}

NodeVMSpecialSandbox::NodeVMSpecialSandbox(VM& vm, Structure* structure, NodeVMGlobalObject* globalObject)
    : Base(vm, structure)
{
    m_parentGlobal.set(vm, this, globalObject);
}

void NodeVMSpecialSandbox::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

const JSC::ClassInfo NodeVMSpecialSandbox::s_info = { "NodeVMSpecialSandbox"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NodeVMSpecialSandbox) };

template<typename Visitor>
void NodeVMSpecialSandbox::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* thisObject = uncheckedDowncast<NodeVMSpecialSandbox>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
    visitor.append(thisObject->m_parentGlobal);
}

DEFINE_VISIT_CHILDREN(NodeVMSpecialSandbox);

NodeVMGlobalObject::NodeVMGlobalObject(JSC::VM& vm, JSC::Structure* structure, NodeVMContextOptions contextOptions, JSValue importer)
    : Base(vm, structure, &globalObjectMethodTable())
    , m_dynamicImportCallback(vm, this, importer)
    , m_contextOptions(contextOptions)
{
}

template<typename, JSC::SubspaceAccess mode> JSC::GCClient::IsoSubspace* NodeVMGlobalObject::subspaceFor(JSC::VM& vm)
{
    if constexpr (mode == JSC::SubspaceAccess::Concurrently)
        return nullptr;
    return WebCore::subspaceForImpl<NodeVMGlobalObject, WebCore::UseCustomHeapCellType::Yes>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForNodeVMGlobalObject.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForNodeVMGlobalObject = std::forward<decltype(space)>(space); },
        [](auto& spaces) { return spaces.m_subspaceForNodeVMGlobalObject.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForNodeVMGlobalObject = std::forward<decltype(space)>(space); },
        [](auto& server) -> JSC::HeapCellType& { return server.m_heapCellTypeForNodeVMGlobalObject; });
}

NodeVMGlobalObject* NodeVMGlobalObject::create(JSC::VM& vm, JSC::Structure* structure, NodeVMContextOptions options, JSValue importer)
{
    auto* cell = new (NotNull, JSC::allocateCell<NodeVMGlobalObject>(vm)) NodeVMGlobalObject(vm, structure, options, importer);
    cell->finishCreation(vm);
    return cell;
}

Structure* NodeVMGlobalObject::createStructure(JSC::VM& vm, JSC::JSValue prototype)
{
    // ~IsImmutablePrototypeExoticObject is necessary for JSDOM to work (it relies on __proto__ = on the GlobalObject).
    return JSC::Structure::create(vm, nullptr, prototype, JSC::TypeInfo(JSC::GlobalObjectType, StructureFlags & ~IsImmutablePrototypeExoticObject), info());
}

void unsafeEvalNoop(JSGlobalObject*, const WTF::String&) {}

static void promiseRejectionTrackerForNodeVM(JSGlobalObject* globalObject, JSC::JSPromise* promise, JSC::JSPromiseRejectionOperation operation)
{
    // Delegate to the parent Zig::GlobalObject so that unhandled rejections
    // in VM contexts are reported to the main process (matching Node.js behavior)
    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    Zig::GlobalObject::promiseRejectionTracker(zigGlobalObject, promise, operation);
}

const JSC::GlobalObjectMethodTable& NodeVMGlobalObject::globalObjectMethodTable()
{
    static const JSC::GlobalObjectMethodTable table {
        &supportsRichSourceInfo,
        &shouldInterruptScript,
        &javaScriptRuntimeFlags,
        nullptr, // shouldInterruptScriptBeforeTimeout,
        &moduleLoaderImportModule,
        nullptr, // moduleLoaderResolve
        nullptr, // moduleLoaderFetch
        nullptr, // moduleLoaderCreateImportMetaProperties
        nullptr, // moduleLoaderEvaluate
        &Zig::GlobalObject::moduleLoaderAnalyzeTranspiledModule,
        &promiseRejectionTrackerForNodeVM,
        &reportUncaughtExceptionAtEventLoop,
        &currentScriptExecutionOwner,
        &scriptExecutionStatus,
        &unsafeEvalNoop, // reportViolationForUnsafeEval
        nullptr, // defaultLanguage
        nullptr, // compileStreaming
        nullptr, // instantiateStreaming
        nullptr,
        &codeForEval,
        &canCompileStrings,
        &trustedScriptStructure,
        &Zig::GlobalObject::runNativeMicrotask,
        &Zig::GlobalObject::destroyNativeMicrotask,
    };
    return table;
}

void NodeVMGlobalObject::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    setEvalEnabled(m_contextOptions.allowStrings, "Code generation from strings disallowed for this context"_s);
    setWebAssemblyEnabled(m_contextOptions.allowWasm, "Wasm code generation disallowed by embedder"_s);

    // Delete the internal Loader property from the VM global object.
    // This is exposed by JSC when exposeInternalModuleLoader() is true,
    // but it should not be visible in node:vm contexts.
    JSC::DeletePropertySlot slot;
    JSC::JSObject::deleteProperty(this, this, vm.propertyNames->Loader, slot);

    vm.ensureTerminationException();

    // Share the async context data with the parent Zig::GlobalObject.
    // This is necessary because AsyncLocalStorage methods (run, getStore, etc.) are defined
    // in the parent realm and reference the parent's $asyncContext. However, microtask
    // processing (JSMicrotask.cpp) operates on this NodeVMGlobalObject's m_asyncContextData.
    // By sharing the same InternalFieldTuple, both the JS code and C++ microtask handling
    // will operate on the same async context, ensuring proper AsyncLocalStorage behavior
    // across await boundaries in VM contexts.
    auto* parentGlobalObject = defaultGlobalObject(this);
    if (parentGlobalObject && parentGlobalObject->m_asyncContextData) {
        m_asyncContextData.set(vm, this, parentGlobalObject->m_asyncContextData.get());
        if (parentGlobalObject->isAsyncContextTrackingEnabled())
            setAsyncContextTrackingEnabled(true);
    }
}

void NodeVMGlobalObject::destroy(JSCell* cell)
{
    static_cast<NodeVMGlobalObject*>(cell)->~NodeVMGlobalObject();
}

NodeVMGlobalObject::~NodeVMGlobalObject()
{
    SigintWatcher::get().unregisterGlobalObject(this);
}

void NodeVMGlobalObject::setContextifiedObject(JSC::JSObject* contextifiedObject)
{
    m_sandbox.set(vm(), this, contextifiedObject);
}

void NodeVMGlobalObject::clearContextifiedObject()
{
    m_sandbox.clear();
}

void NodeVMGlobalObject::sigintReceived()
{
    vm().notifyNeedTermination();
}

bool NodeVMGlobalObject::put(JSCell* cell, JSGlobalObject* globalObject, PropertyName propertyName, JSValue value, PutPropertySlot& slot)
{
    auto* thisObject = uncheckedDowncast<NodeVMGlobalObject>(cell);

    if (!thisObject->m_sandbox) {
        return Base::put(cell, globalObject, propertyName, value, slot);
    }

    auto* sandbox = thisObject->m_sandbox.get();

    VM& vm = JSC::getVM(globalObject);
    JSValue thisValue = slot.thisValue();
    bool isContextualStore = thisValue != JSValue(globalObject);
    if (auto* proxy = dynamicDowncast<JSGlobalProxy>(thisValue); proxy && proxy->target() == globalObject) {
        isContextualStore = false;
    }
    bool isDeclaredOnGlobalObject = slot.type() == JSC::PutPropertySlot::NewProperty;
    auto scope = DECLARE_THROW_SCOPE(vm);
    PropertySlot getter(sandbox, PropertySlot::InternalMethodType::Get, nullptr);
    bool isDeclaredOnSandbox = sandbox->getPropertySlot(globalObject, propertyName, getter);
    RETURN_IF_EXCEPTION(scope, false);

    bool isDeclared = isDeclaredOnGlobalObject || isDeclaredOnSandbox;
    bool isFunction = value.isCallable();

    if (slot.isStrictMode() && !isDeclared && isContextualStore && !isFunction) {
        RELEASE_AND_RETURN(scope, Base::put(cell, globalObject, propertyName, value, slot));
    }

    if (!isDeclared && value.isSymbol()) {
        RELEASE_AND_RETURN(scope, Base::put(cell, globalObject, propertyName, value, slot));
    }

    if (thisObject->m_contextOptions.notContextified) {
        JSObject* specialSandbox = thisObject->specialSandbox();
        slot.setThisValue(specialSandbox);
        RELEASE_AND_RETURN(scope, specialSandbox->putInline(globalObject, propertyName, value, slot));
    }

    slot.setThisValue(sandbox);

    bool result = sandbox->methodTable()->put(sandbox, globalObject, propertyName, value, slot);
    RETURN_IF_EXCEPTION(scope, false);
    if (!result) return false;

    if (isDeclaredOnSandbox && getter.isAccessor() and (getter.attributes() & PropertyAttribute::DontEnum) == 0) {
        return true;
    }

    slot.setThisValue(thisValue);
    RELEASE_AND_RETURN(scope, Base::put(cell, globalObject, propertyName, value, slot));
}

// This is copy-pasted from JSC's ProxyObject.cpp
static const ASCIILiteral s_proxyAlreadyRevokedErrorMessage { "Proxy has already been revoked. No more operations are allowed to be performed on it"_s };

bool NodeVMSpecialSandbox::getOwnPropertySlot(JSObject* cell, JSGlobalObject* globalObject, PropertyName propertyName, PropertySlot& slot)
{
    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* thisObject = uncheckedDowncast<NodeVMSpecialSandbox>(cell);
    NodeVMGlobalObject* parentGlobal = thisObject->parentGlobal();

    if (propertyName == vm.propertyNames->globalThis) [[unlikely]] {
        slot.disableCaching();
        slot.setThisValue(thisObject);
        slot.setValue(thisObject, slot.attributes(), thisObject);
        return true;
    }

    bool result = parentGlobal->getOwnPropertySlot(parentGlobal, globalObject, propertyName, slot);
    RETURN_IF_EXCEPTION(scope, false);

    if (result) {
        return true;
    }

    RELEASE_AND_RETURN(scope, Base::getOwnPropertySlot(cell, globalObject, propertyName, slot));
}

bool NodeVMGlobalObject::getOwnPropertySlot(JSObject* cell, JSGlobalObject* globalObject, PropertyName propertyName, PropertySlot& slot)
{
    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* thisObject = uncheckedDowncast<NodeVMGlobalObject>(cell);

    bool notContextified = thisObject->isNotContextified();

    if (notContextified && propertyName == vm.propertyNames->globalThis) [[unlikely]] {
        slot.disableCaching();
        slot.setThisValue(thisObject);
        slot.setValue(thisObject, slot.attributes(), thisObject->specialSandbox());
        return true;
    }

    if (JSObject* contextifiedObject = thisObject->contextifiedObject()) {
        slot.setThisValue(contextifiedObject);
        // Unfortunately we must special case ProxyObjects. Why?
        //
        // When we run this:
        //
        // ```js
        // vm.runInNewContext("String", new Proxy({}, {}))
        // ```
        //
        // It always returns undefined (it should return the String constructor function).
        //
        // This is because JSC seems to always return true when calling
        // `contextifiedObject->methodTable()->getOwnPropertySlot` for ProxyObjects, so
        // we never fall through to call `Base::getOwnPropertySlot` to fetch it from the globalObject.
        //
        // This only happens when `slot.internalMethodType() == JSC::PropertySlot::InternalMethodType::Get`
        // and there is no `get` trap set on the proxy object.
        if (slot.internalMethodType() == JSC::PropertySlot::InternalMethodType::Get && contextifiedObject->type() == JSC::ProxyObjectType) {
            JSC::ProxyObject* proxyObject = uncheckedDowncast<JSC::ProxyObject>(contextifiedObject);

            if (proxyObject->isRevoked())
                return throwTypeError(globalObject, scope, s_proxyAlreadyRevokedErrorMessage);

            JSValue handlerValue = proxyObject->handler();
            if (!handlerValue.isObject())
                return throwTypeError(globalObject, scope, s_proxyAlreadyRevokedErrorMessage);
            JSObject* handler = uncheckedDowncast<JSObject>(handlerValue);
            CallData callData;
            JSObject* getHandler = proxyObject->getHandlerTrap(globalObject, handler, callData, vm.propertyNames->get, ProxyObject::HandlerTrap::Get);
            RETURN_IF_EXCEPTION(scope, {});

            // If there is a `get` trap, we don't need to our special handling
            if (getHandler) {
                if (contextifiedObject->methodTable()->getOwnPropertySlot(contextifiedObject, globalObject, propertyName, slot)) {
                    return true;
                }
                goto try_from_global;
            }

            // A lot of this is copy-pasted from JSC's `ProxyObject::getOwnPropertySlotCommon` function in
            // ProxyObject.cpp, need to make sure we keep this in sync when we update JSC...

            slot.disableCaching();
            slot.setIsTaintedByOpaqueObject();

            if (slot.isVMInquiry()) {
                goto try_from_global;
            }

            JSValue receiver = slot.thisValue();

            // We're going to have to look this up ourselves
            PropertySlot target_slot(receiver, PropertySlot::InternalMethodType::Get);
            JSObject* target = proxyObject->target();
            bool hasProperty = target->getPropertySlot(globalObject, propertyName, target_slot);
            EXCEPTION_ASSERT(!scope.exception() || !hasProperty);
            if (hasProperty) {
                unsigned ignoredAttributes = 0;
                JSValue result = target_slot.getValue(globalObject, propertyName);
                RETURN_IF_EXCEPTION(scope, {});
                slot.setValue(proxyObject, ignoredAttributes, result);
                RETURN_IF_EXCEPTION(scope, {});
                return true;
            }

            goto try_from_global;
        }

        if (!notContextified) {
            bool result = contextifiedObject->getPropertySlot(globalObject, propertyName, slot);
            RETURN_IF_EXCEPTION(scope, false);
            if (result) return true;
        }

    try_from_global:

        slot.setThisValue(globalObject);
        RETURN_IF_EXCEPTION(scope, false);
    }

    bool result = Base::getOwnPropertySlot(cell, globalObject, propertyName, slot);
    RETURN_IF_EXCEPTION(scope, false);

    if (result) {
        return true;
    }

    if (thisObject->m_contextOptions.notContextified) {
        JSObject* specialSandbox = thisObject->specialSandbox();
        RELEASE_AND_RETURN(scope, JSObject::getOwnPropertySlot(specialSandbox, globalObject, propertyName, slot));
    }

    return false;
}

bool NodeVMGlobalObject::defineOwnProperty(JSObject* cell, JSGlobalObject* globalObject, PropertyName propertyName, const PropertyDescriptor& descriptor, bool shouldThrow)
{
    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* thisObject = uncheckedDowncast<NodeVMGlobalObject>(cell);
    if (!thisObject->m_sandbox) [[likely]] {
        RELEASE_AND_RETURN(scope, Base::defineOwnProperty(cell, globalObject, propertyName, descriptor, shouldThrow));
    }

    auto* contextifiedObject = thisObject->isNotContextified() ? thisObject->specialSandbox() : thisObject->m_sandbox.get();

    PropertySlot slot(globalObject, PropertySlot::InternalMethodType::GetOwnProperty, nullptr);
    bool isDeclaredOnGlobalProxy = globalObject->JSC::JSGlobalObject::getOwnPropertySlot(globalObject, globalObject, propertyName, slot);

    // If the property is set on the global as neither writable nor
    // configurable, don't change it on the global or sandbox.
    if (isDeclaredOnGlobalProxy && (slot.attributes() & PropertyAttribute::ReadOnly) != 0 && (slot.attributes() & PropertyAttribute::DontDelete) != 0) {
        RELEASE_AND_RETURN(scope, Base::defineOwnProperty(cell, globalObject, propertyName, descriptor, shouldThrow));
    }

    if (descriptor.isAccessorDescriptor()) {
        RELEASE_AND_RETURN(scope, contextifiedObject->defineOwnProperty(contextifiedObject, contextifiedObject->globalObject(), propertyName, descriptor, shouldThrow));
    }

    bool isDeclaredOnSandbox = contextifiedObject->getPropertySlot(globalObject, propertyName, slot);
    RETURN_IF_EXCEPTION(scope, false);

    if (isDeclaredOnSandbox && !isDeclaredOnGlobalProxy) {
        RELEASE_AND_RETURN(scope, contextifiedObject->defineOwnProperty(contextifiedObject, contextifiedObject->globalObject(), propertyName, descriptor, shouldThrow));
    }

    auto did = contextifiedObject->defineOwnProperty(contextifiedObject, contextifiedObject->globalObject(), propertyName, descriptor, shouldThrow);
    RETURN_IF_EXCEPTION(scope, false);
    if (!did) return false;

    RELEASE_AND_RETURN(scope, Base::defineOwnProperty(cell, globalObject, propertyName, descriptor, shouldThrow));
}

DEFINE_VISIT_CHILDREN(NodeVMGlobalObject);

template<typename Visitor>
void NodeVMGlobalObject::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    Base::visitChildren(cell, visitor);
    auto* thisObject = uncheckedDowncast<NodeVMGlobalObject>(cell);
    visitor.append(thisObject->m_sandbox);
    visitor.append(thisObject->m_specialSandbox);
    visitor.append(thisObject->m_dynamicImportCallback);
}

static EncodedJSValue compileFunctionBinding(JSGlobalObject* globalObject, const WTF::String& code, const WTF::Vector<WTF::String>& parameters, CompileFunctionOptions&& options, JSValue importer)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    MarkedArgumentBuffer constructFunctionArgs;

    for (const auto& parameter : parameters)
        constructFunctionArgs.append(jsString(vm, parameter));

    constructFunctionArgs.append(jsString(vm, code));
    if (constructFunctionArgs.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    RefPtr fetcher(NodeVMScriptFetcher::create(vm, importer, jsUndefined()));

    // Create the source origin
    SourceOrigin sourceOrigin { WTF::URL::fileURLWithFileSystemPath(options.filename), *fetcher };

    JSScope* functionScope = options.parsingContext ? options.parsingContext : globalObject;

    if (!options.contextExtensions.isEmpty()) {
        JSScope* currentScope = options.parsingContext->globalScope();
        for (const auto& extension : options.contextExtensions)
            currentScope = JSWithScope::create(vm, options.parsingContext, currentScope, extension.get());
        functionScope = currentScope;
    }

    options.parsingContext->setGlobalScopeExtension(functionScope);

    // Create the function using constructAnonymousFunction with the appropriate scope chain
    JSFunction* function = constructAnonymousFunction(globalObject, ArgList(constructFunctionArgs), sourceOrigin, WTF::move(options), JSC::SourceTaintedOrigin::Untainted, functionScope);
    RETURN_IF_EXCEPTION(scope, {});

    if (!function) {
        return throwVMError(globalObject, scope, "Failed to compile function"_s);
    }

    fetcher->owner(vm, function);

    return JSValue::encode(function);
}

Structure* createNodeVMGlobalObjectStructure(JSC::VM& vm)
{
    return NodeVMGlobalObject::createStructure(vm, jsNull());
}

static EncodedJSValue createContextBinding(JSGlobalObject* globalObject, const Bindgen::NodeVMContextInput& contextValue, NodeVMContextOptions contextOptions, JSValue importer)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto contextInput = resolveContextInput(globalObject, contextValue);
    RETURN_IF_EXCEPTION(scope, {});

    contextOptions.notContextified = contextInput.notContextified;
    JSObject* sandbox = contextInput.sandbox;

    if (isContext(globalObject, sandbox)) {
        if (auto* proxy = dynamicDowncast<JSC::JSGlobalProxy>(sandbox)) {
            if (auto* targetContext = dynamicDowncast<NodeVMGlobalObject>(proxy->target())) {
                if (targetContext->isNotContextified()) {
                    return JSValue::encode(targetContext->specialSandbox());
                }
            }
        }
        return JSValue::encode(sandbox);
    }

    auto* zigGlobalObject = defaultGlobalObject(globalObject);

    auto* targetContext = NodeVMGlobalObject::create(vm,
        zigGlobalObject->NodeVMGlobalObjectStructure(),
        contextOptions, importer);

    RETURN_IF_EXCEPTION(scope, {});

    // Set sandbox as contextified object
    targetContext->setContextifiedObject(sandbox);

    // Store context in WeakMap for isContext checks
    zigGlobalObject->vmModuleContextMap()->set(vm, sandbox, targetContext);
    RETURN_IF_EXCEPTION(scope, {});

    if (contextInput.notContextified) {
        auto* specialSandbox = NodeVMSpecialSandbox::create(vm, zigGlobalObject->NodeVMSpecialSandboxStructure(), targetContext);
        RETURN_IF_EXCEPTION(scope, {});
        targetContext->setSpecialSandbox(specialSandbox);
        return JSValue::encode(targetContext->specialSandbox());
    }

    return JSValue::encode(sandbox);
}

const ClassInfo NodeVMGlobalObject::s_info = { "NodeVMGlobalObject"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NodeVMGlobalObject) };

bool NodeVMGlobalObject::deleteProperty(JSCell* cell, JSGlobalObject* globalObject, PropertyName propertyName, JSC::DeletePropertySlot& slot)
{
    auto* thisObject = uncheckedDowncast<NodeVMGlobalObject>(cell);
    if (!thisObject->m_sandbox) [[unlikely]] {
        return Base::deleteProperty(cell, globalObject, propertyName, slot);
    }

    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* sandbox = thisObject->m_sandbox.get();
    if (!sandbox->deleteProperty(sandbox, globalObject, propertyName, slot)) {
        return false;
    }

    RETURN_IF_EXCEPTION(scope, false);
    return Base::deleteProperty(cell, globalObject, propertyName, slot);
}

static JSPromise* moduleLoaderImportModuleInner(NodeVMGlobalObject* globalObject, JSC::JSModuleLoader* moduleLoader, JSC::JSString* moduleName, RefPtr<JSC::ScriptFetchParameters> parameters, const JSC::SourceOrigin& sourceOrigin)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* promise = JSPromise::create(vm, globalObject->promiseStructure());

    if (sourceOrigin.fetcher() == nullptr && sourceOrigin.url().isEmpty()) {
        if (globalObject->dynamicImportCallback().isCallable()) {
            RELEASE_AND_RETURN(scope, NodeVM::importModuleInner(globalObject, moduleName, WTF::move(parameters), sourceOrigin, globalObject->dynamicImportCallback(), JSValue {}));
        }

        promise->reject(vm, createError(globalObject, ErrorCode::ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING, "A dynamic import callback was not specified."_s));
        return promise;
    }

    // Default behavior copied from JSModuleLoader::importModule
    auto moduleNameString = moduleName->value(globalObject);
    RETURN_IF_EXCEPTION(scope, promise->rejectWithCaughtException(vm, scope));

    scope.release();
    promise->reject(vm, createError(globalObject, makeString("Could not import the module '"_s, moduleNameString.data, "'."_s)));
    return promise;
}

JSPromise* NodeVMGlobalObject::moduleLoaderImportModule(JSGlobalObject* globalObject, JSC::JSModuleLoader* moduleLoader, JSC::JSString* moduleName, RefPtr<JSC::ScriptFetchParameters> parameters, const JSC::SourceOrigin& sourceOrigin, bool deferred)
{
    UNUSED_PARAM(deferred);
    auto* nodeVmGlobalObject = static_cast<NodeVMGlobalObject*>(globalObject);
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* result = NodeVM::importModule(nodeVmGlobalObject, moduleName, parameters, sourceOrigin);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (result) {
        return result;
    }

    RELEASE_AND_RETURN(scope, moduleLoaderImportModuleInner(nodeVmGlobalObject, moduleLoader, moduleName, WTF::move(parameters), sourceOrigin));
}

void NodeVMGlobalObject::getOwnPropertyNames(JSObject* cell, JSGlobalObject* globalObject, JSC::PropertyNameArrayBuilder& propertyNames, JSC::DontEnumPropertiesMode mode)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* thisObject = uncheckedDowncast<NodeVMGlobalObject>(cell);

    if (thisObject->m_sandbox) {
        thisObject->m_sandbox->getOwnPropertyNames(thisObject->m_sandbox.get(), globalObject, propertyNames, mode);
        RETURN_IF_EXCEPTION(scope, );
    }

    RELEASE_AND_RETURN(scope, Base::getOwnPropertyNames(cell, globalObject, propertyNames, mode));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_compileFunction(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_compileFunction_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    const WTF::Vector<WTF::String> emptyParams;
    auto resolved = resolveCompileFunctionOptions(&context.globalObject, args.options);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(resolved);
    RELEASE_AND_RETURN(scope, JSValue::decode(compileFunctionBinding(
        &context.globalObject,
        args.code,
        args.params ? *args.params : emptyParams,
        WTF::move(resolved->options),
        resolved->importer)));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_createContext(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_createContext_Arguments& args)
{
    auto resolved = resolveContextOptions(args.options);
    return JSValue::decode(createContextBinding(
        &context.globalObject,
        args.context,
        resolved.options,
        resolved.importer));
}

bool Bindgen::Cpp::bunBindgenCpp_NodeVM_isContext(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_isContext_Arguments& args)
{
    return isContext(&context.globalObject, args.object);
}

bool Bindgen::Cpp::bunBindgenCpp_NodeVM_isModuleNamespaceObject(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_isModuleNamespaceObject_Arguments& args)
{
    return args.value && args.value->is_object() && args.value->object().inherits(JSModuleNamespaceObject::info());
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleNamespaceOrOriginal(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleNamespaceOrOriginal_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (auto* object = args.value.getObject()) {
        auto result = object->get(&globalObject, JSC::Identifier::fromString(vm, "namespace"_s));
        RETURN_IF_EXCEPTION(scope, {});
        if (!result.isUndefinedOrNull())
            return result;
    }
    return args.value;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptConstructor_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->NodeVMScript();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleConstructor_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->NodeVMSourceTextModule();
}

uint32_t Bindgen::Cpp::bunBindgenCpp_NodeVM_unlinkedStatus(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_unlinkedStatus_Arguments&)
{
    return static_cast<uint32_t>(NodeVMSourceTextModule::Status::Unlinked);
}

uint32_t Bindgen::Cpp::bunBindgenCpp_NodeVM_linkedStatus(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_linkedStatus_Arguments&)
{
    return static_cast<uint32_t>(NodeVMSourceTextModule::Status::Linked);
}

uint32_t Bindgen::Cpp::bunBindgenCpp_NodeVM_evaluatedStatus(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_evaluatedStatus_Arguments&)
{
    return static_cast<uint32_t>(NodeVMSourceTextModule::Status::Evaluated);
}

uint32_t Bindgen::Cpp::bunBindgenCpp_NodeVM_erroredStatus(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_erroredStatus_Arguments&)
{
    return static_cast<uint32_t>(NodeVMSourceTextModule::Status::Errored);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_dontContextify(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_dontContextify_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return globalObject->m_nodeVMDontContextify.get(globalObject);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_useMainContextDefaultLoader(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_useMainContextDefaultLoader_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return globalObject->m_nodeVMUseMainContextDefaultLoader.get(globalObject);
}

void configureNodeVM(JSC::VM& vm, Zig::GlobalObject* globalObject)
{
    globalObject->m_nodeVMDontContextify.initLater([](const LazyProperty<JSC::JSGlobalObject, Symbol>::Initializer& init) {
        init.set(JSC::Symbol::createWithDescription(init.vm, "vm_dont_contextify"_s));
    });
    globalObject->m_nodeVMUseMainContextDefaultLoader.initLater([](const LazyProperty<JSC::JSGlobalObject, Symbol>::Initializer& init) {
        init.set(JSC::Symbol::createWithDescription(init.vm, "vm_use_main_context_default_loader"_s));
    });

    globalObject->m_NodeVMScriptClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            auto prototype = NodeVMScript::createPrototype(init.vm, init.global);
            auto* structure = NodeVMScript::createStructure(init.vm, init.global, prototype);
            auto* constructorStructure = NodeVMScriptConstructor::createStructure(
                init.vm, init.global, init.global->m_functionPrototype.get());
            auto* constructor = NodeVMScriptConstructor::create(
                init.vm, init.global, constructorStructure, prototype);
            init.setPrototype(prototype);
            init.setStructure(structure);
            init.setConstructor(constructor);
        });

    globalObject->m_NodeVMSourceTextModuleClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            auto prototype = NodeVMSourceTextModule::createPrototype(init.vm, init.global);
            auto* structure = NodeVMSourceTextModule::createStructure(init.vm, init.global, prototype);
            auto* constructorStructure = NodeVMModuleConstructor::createStructure(
                init.vm, init.global, init.global->m_functionPrototype.get());
            auto* constructor = NodeVMModuleConstructor::create(
                init.vm, init.global, constructorStructure, prototype);
            init.setPrototype(prototype);
            init.setStructure(structure);
            init.setConstructor(constructor);
        });

    globalObject->m_NodeVMSyntheticModuleClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            auto prototype = NodeVMSyntheticModule::createPrototype(init.vm, init.global);
            auto* structure = NodeVMSyntheticModule::createStructure(init.vm, init.global, prototype);
            auto* constructorStructure = NodeVMModuleConstructor::createStructure(
                init.vm, init.global, init.global->m_functionPrototype.get());
            auto* constructor = NodeVMModuleConstructor::create(
                init.vm, init.global, constructorStructure, prototype);
            init.setPrototype(prototype);
            init.setStructure(structure);
            init.setConstructor(constructor);
        });

    globalObject->m_cachedNodeVMGlobalObjectStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
            init.set(createNodeVMGlobalObjectStructure(init.vm));
        });

    globalObject->m_cachedNodeVMSpecialSandboxStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
            init.set(NodeVMSpecialSandbox::createStructure(init.vm, init.owner, init.owner->objectPrototype())); // TODO(@heimskr): or maybe jsNull() for the prototype?
        });
}

BaseVMOptions::BaseVMOptions(String filename)
    : filename(WTF::move(filename))
{
}

BaseVMOptions::BaseVMOptions(String filename, OrdinalNumber lineOffset, OrdinalNumber columnOffset)
    : filename(WTF::move(filename))
    , lineOffset(lineOffset)
    , columnOffset(columnOffset)
{
}

} // namespace Bun
