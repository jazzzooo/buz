#include "NodeVMScript.h"
#include "SchemaBindings.h"
#include "NodeVMBindingOptions.h"
#include "WebCoreJSBuiltins.h"
#include "JSBuffer.h"

#include "ErrorCode.h"

#include "JavaScriptCore/Completion.h"
#include "JavaScriptCore/JIT.h"
#include "JavaScriptCore/JSWeakMap.h"
#include "JavaScriptCore/JSWeakMapInlines.h"
#include "JavaScriptCore/ProgramCodeBlock.h"
#include "JavaScriptCore/SourceCodeKey.h"

#include "NodeVMScriptFetcher.h"
#include "../vm/SigintWatcher.h"

#include <bit>

namespace Bun {
using namespace NodeVM;

static NodeVMScript* nodeVMScript(JSC::JSValue value)
{
    auto* script = dynamicDowncast<NodeVMScript>(value);
    RELEASE_ASSERT(script);
    return script;
}

static EncodedJSValue
constructScript(JSGlobalObject* globalObject, const WTF::String& sourceString, ScriptOptions&& options, JSValue importer, JSObject* newTarget = nullptr)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    Structure* structure = zigGlobalObject->NodeVMScriptStructure();
    if (zigGlobalObject->NodeVMScript() != newTarget) [[unlikely]] {
        if (!newTarget) {
            throwTypeError(globalObject, scope, "Class constructor Script cannot be invoked without 'new'"_s);
            return {};
        }

        auto* functionGlobalObject = defaultGlobalObject(getFunctionRealm(globalObject, newTarget));
        RETURN_IF_EXCEPTION(scope, {});
        structure = InternalFunction::createSubclassStructure(globalObject, newTarget, functionGlobalObject->NodeVMScriptStructure());
        RETURN_IF_EXCEPTION(scope, {});
    }

    RefPtr fetcher(NodeVMScriptFetcher::create(vm, importer, jsUndefined()));

    SourceCode source = makeSource(sourceString, JSC::SourceOrigin(WTF::URL::fileURLWithFileSystemPath(options.filename), *fetcher), JSC::SourceTaintedOrigin::Untainted, options.filename, TextPosition(options.lineOffset, options.columnOffset));
    RETURN_IF_EXCEPTION(scope, {});

    const bool produceCachedData = options.produceCachedData;
    auto filename = options.filename;

    NodeVMScript* script = NodeVMScript::create(vm, globalObject, structure, WTF::move(source), WTF::move(options));
    RETURN_IF_EXCEPTION(scope, {});

    fetcher->owner(vm, script);

    WTF::Vector<uint8_t>& cachedData = script->cachedData();

    if (!cachedData.isEmpty()) {
        JSC::ProgramExecutable* executable = script->cachedExecutable();
        if (!executable) {
            executable = script->createExecutable();
        }
        ASSERT(executable);

        JSC::LexicallyScopedFeatures lexicallyScopedFeatures = globalObject->globalScopeExtension() ? JSC::TaintedByWithScopeLexicallyScopedFeature : JSC::NoLexicallyScopedFeatures;
        JSC::SourceCodeKey key(script->source(), {}, JSC::SourceCodeType::ProgramType, lexicallyScopedFeatures, JSC::JSParserScriptMode::Classic, JSC::DerivedContextType::None, JSC::EvalContextType::None, false, {}, std::nullopt);
        Ref<JSC::CachedBytecode> cachedBytecode = JSC::CachedBytecode::create(std::span(cachedData), nullptr, {});
        JSC::UnlinkedProgramCodeBlock* unlinkedBlock = JSC::decodeCodeBlock<UnlinkedProgramCodeBlock>(vm, key, WTF::move(cachedBytecode));

        if (!unlinkedBlock) {
            script->cachedDataRejected(TriState::True);
        } else {
            JSC::JSScope* jsScope = globalObject->globalScope();
            JSC::CodeBlock* codeBlock = nullptr;
            {
                // JSC::ProgramCodeBlock::create() requires GC to be deferred.
                DeferGC deferGC(vm);
                codeBlock = JSC::ProgramCodeBlock::create(vm, executable, unlinkedBlock, jsScope);
                RETURN_IF_EXCEPTION(scope, {});
            }
            JSC::CompilationResult compilationResult = JIT::compileSync(vm, codeBlock, JITCompilationEffort::JITCompilationCanFail);
            if (compilationResult != JSC::CompilationResult::CompilationFailed) {
                executable->installCode(codeBlock);
                script->cachedDataRejected(TriState::False);
            } else {
                script->cachedDataRejected(TriState::True);
            }
        }
    } else if (produceCachedData) {
        script->cacheBytecode();
        // TODO(@heimskr): is there ever a case where bytecode production fails?
        script->cachedDataProduced(true);
    }

    return JSValue::encode(script);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptConstructorCall_Arguments& args)
{
    auto resolved = resolveScriptOptions(args.options);
    return JSValue::decode(constructScript(
        &context.globalObject,
        args.source ? *args.source : WTF::emptyString(),
        WTF::move(resolved.options),
        resolved.importer));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptConstructorConstruct_Arguments& args)
{
    auto resolved = resolveScriptOptions(args.options);
    return JSValue::decode(constructScript(
        &context.globalObject,
        args.source ? *args.source : WTF::emptyString(),
        WTF::move(resolved.options),
        resolved.importer,
        JSC::asObject(args.bindingNewTarget)));
}

JSC::ProgramExecutable* NodeVMScript::createExecutable()
{
    VM& vm = JSC::getVM(globalObject());
    m_cachedExecutable.set(vm, this, JSC::ProgramExecutable::create(globalObject(), m_source));
    return m_cachedExecutable.get();
}

void NodeVMScript::cacheBytecode()
{
    if (!m_cachedExecutable) {
        createExecutable();
    }

    m_cachedBytecode = getBytecode(globalObject(), m_cachedExecutable.get(), m_source);
    m_cachedDataProduced = m_cachedBytecode != nullptr;
}

JSC::JSUint8Array* NodeVMScript::getBytecodeBuffer()
{
    if (!m_options.produceCachedData) {
        return nullptr;
    }

    if (!m_cachedBytecodeBuffer) {
        if (!m_cachedBytecode) {
            cacheBytecode();
        }

        ASSERT(m_cachedBytecode);

        std::span<const uint8_t> bytes = m_cachedBytecode->span();
        m_cachedBytecodeBuffer.set(vm(), this, WebCore::createBuffer(globalObject(), bytes));
        if (!m_cachedBytecodeBuffer) {
            return nullptr;
        }
    }

    ASSERT(m_cachedBytecodeBuffer);
    return m_cachedBytecodeBuffer.get();
}

DEFINE_VISIT_CHILDREN(NodeVMScript);

template<typename Visitor>
void NodeVMScript::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    NodeVMScript* thisObject = uncheckedDowncast<NodeVMScript>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
    visitor.append(thisObject->m_cachedExecutable);
    visitor.append(thisObject->m_cachedBytecodeBuffer);
}

NodeVMScriptConstructor::NodeVMScriptConstructor(VM& vm, Structure* structure)
    : NodeVMScriptConstructor::Base(vm, structure, bun_bindgen_host_NodeVM_scriptConstructorCall, bun_bindgen_host_NodeVM_scriptConstructorConstruct)
{
}

NodeVMScriptConstructor* NodeVMScriptConstructor::create(VM& vm, JSGlobalObject* globalObject, Structure* structure, JSObject* prototype)
{
    NodeVMScriptConstructor* ptr = new (NotNull, allocateCell<NodeVMScriptConstructor>(vm)) NodeVMScriptConstructor(vm, structure);
    ptr->finishCreation(vm, prototype);
    return ptr;
}

void NodeVMScriptConstructor::finishCreation(VM& vm, JSObject* prototype)
{
    Base::finishCreation(vm, 1, "Script"_s, PropertyAdditionMode::WithStructureTransition);
    putDirectWithoutTransition(vm, vm.propertyNames->prototype, prototype, PropertyAttribute::DontEnum | PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    ASSERT(inherits(info()));
}

NodeVMScript* NodeVMScript::create(VM& vm, JSGlobalObject* globalObject, Structure* structure, SourceCode source, ScriptOptions options)
{
    NodeVMScript* ptr = new (NotNull, allocateCell<NodeVMScript>(vm)) NodeVMScript(vm, structure, WTF::move(source), WTF::move(options));
    ptr->finishCreation(vm);
    return ptr;
}

void NodeVMScript::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

void NodeVMScript::destroy(JSCell* cell)
{
    static_cast<NodeVMScript*>(cell)->NodeVMScript::~NodeVMScript();
}

static bool checkForTermination(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, NodeVMScript* script, std::optional<double> timeout)
{
    if (vm.hasTerminationRequest()) {
        vm.drainMicrotasksForGlobalObject(globalObject);
        vm.clearHasTerminationRequest();
        if (script->getSigintReceived()) {
            script->setSigintReceived(false);
            throwError(globalObject, scope, ErrorCode::ERR_SCRIPT_EXECUTION_INTERRUPTED, "Script execution was interrupted by `SIGINT`"_s);
        } else if (timeout) {
            throwError(globalObject, scope, ErrorCode::ERR_SCRIPT_EXECUTION_TIMEOUT, makeString("Script execution timed out after "_s, *timeout, "ms"_s));
        } else {
            RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("vm.Script terminated due neither to SIGINT nor to timeout");
        }
        return true;
    }

    return false;
}

void setupWatchdog(VM& vm, double timeout, double* oldTimeout, double* newTimeout)
{
    JSC::JSLockHolder locker(vm);
    JSC::Watchdog& dog = vm.ensureWatchdog();
    dog.enteredVM();

    Seconds oldLimit = dog.getTimeLimit();

    if (oldTimeout) {
        *oldTimeout = oldLimit.milliseconds();
    }

    if (oldLimit.isInfinity() || timeout < oldLimit.milliseconds()) {
        dog.setTimeLimit(WTF::Seconds::fromMilliseconds(timeout));
    } else {
        timeout = oldLimit.milliseconds();
    }

    if (newTimeout) {
        *newTimeout = timeout;
    }
}

static JSC::EncodedJSValue runInContext(NodeVMGlobalObject* globalObject, NodeVMScript* script, JSObject* contextifiedObject, const RunningScriptOptions& options)
{
    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    // Set the contextified object before evaluating
    globalObject->setContextifiedObject(contextifiedObject);

    NakedPtr<JSC::Exception> exception;
    JSValue result {};
    auto run = [&] {
        result = JSC::evaluate(globalObject, script->source(), globalObject, exception);
    };

    std::optional<double> oldLimit, newLimit;

    if (options.timeout) {
        setupWatchdog(vm, *options.timeout, &oldLimit.emplace(), &newLimit.emplace());
    }

    script->setSigintReceived(false);

    if (options.breakOnSigint) {
        auto holder = SigintWatcher::hold(globalObject, script);
        run();
    } else {
        run();
    }

    RETURN_IF_EXCEPTION(scope, {});

    if (options.timeout) {
        vm.watchdog()->setTimeLimit(WTF::Seconds::fromMilliseconds(*oldLimit));
    }

    if (checkForTermination(vm, globalObject, scope, script, newLimit)) {
        return {};
    }

    script->setSigintReceived(false);

    if (exception) [[unlikely]] {
        if (handleException(globalObject, vm, exception, scope, options.displayErrors)) {
            return {};
        }
        JSC::throwException(globalObject, scope, exception.get());
        return {};
    }

    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, JSValue::encode(result));
}

static EncodedJSValue runScriptInThisContext(JSGlobalObject* globalObject, NodeVMScript* script, const RunningScriptOptions& options)
{
    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    NakedPtr<JSC::Exception> exception;
    JSValue result {};
    auto run = [&] {
        result = JSC::evaluate(globalObject, script->source(), globalObject, exception);
    };

    std::optional<double> oldLimit, newLimit;

    if (options.timeout) {
        setupWatchdog(vm, *options.timeout, &oldLimit.emplace(), &newLimit.emplace());
    }

    script->setSigintReceived(false);

    if (options.breakOnSigint) {
        auto holder = SigintWatcher::hold(globalObject, script);
        vm.ensureTerminationException();
        run();
    } else {
        run();
    }

    if (options.timeout) {
        vm.watchdog()->setTimeLimit(WTF::Seconds::fromMilliseconds(*oldLimit));
    }

    if (checkForTermination(vm, globalObject, scope, script, newLimit)) {
        return {};
    }

    script->setSigintReceived(false);

    if (exception) [[unlikely]] {
        if (handleException(globalObject, vm, exception, scope, options.displayErrors)) {
            return {};
        }
        JSC::throwException(globalObject, scope, exception.get());
        return {};
    }

    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, JSValue::encode(result));
}

std::optional<WTF::String> Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptSourceMapURL(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptSourceMapURL_Arguments& args)
{
    const String& url = nodeVMScript(args.bindingThis)->source().provider()->sourceMappingURLDirective();

    if (!url)
        return std::nullopt;

    return url;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptCachedData(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptCachedData_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    scope.assertNoExceptionExceptTermination();
    auto* buffer = nodeVMScript(args.bindingThis)->getBytecodeBuffer();
    RETURN_IF_EXCEPTION(scope, {});
    if (!buffer)
        return std::nullopt;
    return buffer;
}

bool Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptCachedDataProduced(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptCachedDataProduced_Arguments& args)
{
    return nodeVMScript(args.bindingThis)->cachedDataProduced();
}

std::optional<bool> Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptCachedDataRejected(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptCachedDataRejected_Arguments& args)
{
    switch (nodeVMScript(args.bindingThis)->cachedDataRejected()) {
    case TriState::True:
        return true;
    case TriState::False:
        return false;
    default:
        return std::nullopt;
    }
}

static EncodedJSValue createScriptCachedData(JSGlobalObject* globalObject, NodeVMScript* script)
{
    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    const JSC::SourceCode& source = script->source();
    RELEASE_AND_RETURN(scope, createCachedData(globalObject, source));
}

static EncodedJSValue runScriptInContext(JSGlobalObject* globalObject, NodeVMScript* script, JSValue contextValue, const RunningScriptOptions& options)
{
    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* contextGlobal = getGlobalObjectFromContext(globalObject, contextValue, false);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(contextGlobal);

    RELEASE_AND_RETURN(scope, runInContext(contextGlobal, script, JSC::asObject(contextValue), options));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptRunInThisContext(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptRunInThisContext_Arguments& args)
{
    auto options = resolveRunningOptions(args.options);
    return JSValue::decode(runScriptInThisContext(
        &context.globalObject,
        nodeVMScript(args.bindingThis),
        options));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptCreateCachedData(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptCreateCachedData_Arguments& args)
{
    return JSValue::decode(createScriptCachedData(
        &context.globalObject,
        nodeVMScript(args.bindingThis)));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_scriptRunInContext(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_scriptRunInContext_Arguments& args)
{
    auto options = resolveRunningOptions(args.options);
    return JSValue::decode(runScriptInContext(
        &context.globalObject,
        nodeVMScript(args.bindingThis),
        args.context,
        options));
}

class NodeVMScriptPrototype final : public JSC::JSNonFinalObject {
public:
    using Base = JSC::JSNonFinalObject;

    static NodeVMScriptPrototype* create(VM& vm, JSGlobalObject* globalObject, Structure* structure)
    {
        NodeVMScriptPrototype* ptr = new (NotNull, allocateCell<NodeVMScriptPrototype>(vm)) NodeVMScriptPrototype(vm, structure);
        ptr->finishCreation(vm);
        return ptr;
    }

    DECLARE_INFO;
    template<typename CellType, SubspaceAccess>
    static GCClient::IsoSubspace* subspaceFor(VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(NodeVMScriptPrototype, Base);
        return &vm.plainObjectSpace();
    }
    static Structure* createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
    {
        return Structure::create(vm, globalObject, prototype, TypeInfo(ObjectType, StructureFlags), info());
    }

private:
    NodeVMScriptPrototype(VM& vm, Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(VM&);
};
STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(NodeVMScriptPrototype, NodeVMScriptPrototype::Base);

#define BUN_BINDGEN_OBJECT_SURFACE_NodeVMScriptPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_NodeVMScriptPrototype

void NodeVMScriptPrototype::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_NodeVMScriptPrototype_install(vm, NodeVMScript::info(), *this);
}

JSObject* NodeVMScript::createPrototype(VM& vm, JSGlobalObject* globalObject)
{
    return NodeVMScriptPrototype::create(vm, globalObject, NodeVMScriptPrototype::createStructure(vm, globalObject, globalObject->objectPrototype()));
}

const ClassInfo NodeVMScript::s_info = { "Script"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NodeVMScript) };
const ClassInfo NodeVMScriptPrototype::s_info = { "Script"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NodeVMScriptPrototype) };
const ClassInfo NodeVMScriptConstructor::s_info = { "Script"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NodeVMScriptConstructor) };

} // namespace Bun
