#include "root.h"

#include "BunClientData.h"
#include "ErrorBindings.h"
#include "SchemaBindings.h"
#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/AggregateError.h>
#include <JavaScriptCore/BytecodeIndex.h>
#include <JavaScriptCore/CodeBlock.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ErrorInstance.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/FunctionExecutable.h>
#include <JavaScriptCore/FunctionCodeBlock.h>
#include <JavaScriptCore/InternalFieldTuple.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSAsyncFunctionGenerator.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSPromiseReaction.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/Options.h>
#include <JavaScriptCore/StackFrame.h>

using namespace JSC;
using namespace WebCore;

JSC::JSObject* Bun::Bindgen::createBindingOutOfMemoryError(JSC::JSGlobalObject* globalObject)
{
    auto* error = JSC::createError(globalObject, "Out of memory"_s, nullptr);
    uncheckedDowncast<JSC::ErrorInstance>(error)->setOutOfMemoryError();
    return error;
}

void Bun::Bindgen::throwBindingOutOfMemoryError(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope)
{
    globalObject->vm().hasExceptionsAfterHandlingTraps();
    RETURN_IF_EXCEPTION(scope, );
    JSC::throwException(globalObject, scope, createBindingOutOfMemoryError(globalObject));
}

std::optional<JSC::JSValue> Bun::extractErrorValue(JSC::JSValue value)
{
    if (!value.isCell())
        return std::nullopt;

    auto* cell = value.asCell();
    switch (cell->type()) {
    case JSC::ErrorInstanceType:
        return value;
    case JSC::CellType:
        if (cell->inherits<JSC::Exception>())
            return uncheckedDowncast<JSC::Exception>(cell)->value();
        break;
    default:
        break;
    }
    return std::nullopt;
}

void Bun::Bindgen::Engine::bunBindgenEngine_errors_throwOutOfMemory(
    EngineCallContext& context,
    const BunBindgenEngine_errors_throwOutOfMemory_Arguments&)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    Bun::Bindgen::throwBindingOutOfMemoryError(&context.globalObject, scope);
}

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_errors_errorCodeStringVMInquiry(
    EngineCallContext& context,
    const BunBindgenEngine_errors_errorCodeStringVMInquiry_Arguments& args)
{
    auto* error = dynamicDowncast<JSC::ErrorInstance>(args.errorValue);
    RELEASE_ASSERT(error);
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    PropertySlot slot(error, PropertySlot::InternalMethodType::VMInquiry, &vm);
    scope.assertNoExceptionExceptTermination();
    auto hasCode = error->getNonIndexPropertySlot(&context.globalObject, WebCore::builtinNames(vm).codePublicName(), slot);
    scope.assertNoExceptionExceptTermination();
    if (!hasCode || slot.isAccessor() || slot.isCustom())
        return std::nullopt;
    auto value = slot.getPureResult();
    if (!value.isString())
        return std::nullopt;
    return value;
}

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_errors_errorOwnCause(
    EngineCallContext& context,
    const BunBindgenEngine_errors_errorOwnCause_Arguments& args)
{
    auto* error = uncheckedDowncast<JSC::ErrorInstance>(args.errorValue);
    auto& vm = context.globalObject.vm();
    auto value = error->getDirect(vm, vm.propertyNames->cause);
    if (!value || !dynamicDowncast<JSC::ErrorInstance>(value))
        return std::nullopt;
    return value;
}

static JSC::JSArray* frameworkRouterScanErrorArrayForNextElement(
    Bun::Bindgen::EngineCallContext& context,
    JSC::JSValue value,
    uint32_t index)
{
    auto* array = dynamicDowncast<JSC::JSArray>(value);
    RELEASE_ASSERT(array);
    RELEASE_ASSERT(index < array->length());
    RELEASE_ASSERT(!array->getDirectIndex(&context.globalObject, index));
    RELEASE_ASSERT(index == 0 || array->getDirectIndex(&context.globalObject, index - 1));
    return array;
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_FrameworkFileSystemRouter_createScanErrorArray(
    EngineCallContext& context,
    const BunBindgenEngine_FrameworkFileSystemRouter_createScanErrorArray_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::constructEmptyArray(&context.globalObject, nullptr, args.length));
}

void Bun::Bindgen::Engine::bunBindgenEngine_FrameworkFileSystemRouter_appendScanError(
    EngineCallContext& context,
    const BunBindgenEngine_FrameworkFileSystemRouter_appendScanError_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* array = frameworkRouterScanErrorArrayForNextElement(context, args.array, args.index);
    auto* error = JSC::createError(&context.globalObject, args.message);
    RETURN_IF_EXCEPTION(scope, );
    array->putDirectIndex(&context.globalObject, args.index, error);
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

void Bun::Bindgen::Engine::bunBindgenEngine_FrameworkFileSystemRouter_throwScanAggregateError(
    EngineCallContext& context,
    const BunBindgenEngine_FrameworkFileSystemRouter_throwScanAggregateError_Arguments& args)
{
    auto& global = context.globalObject;
    auto& vm = global.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* errors = dynamicDowncast<JSC::JSArray>(args.errors);
    RELEASE_ASSERT(errors);
    auto* structure = global.errorStructure(JSC::ErrorType::AggregateError);
    auto* aggregate = JSC::createAggregateError(vm, structure, errors, WTF::String("Errors scanning routes"_s), JSC::jsUndefined(), nullptr, JSC::TypeNothing, false);
    RETURN_IF_EXCEPTION(scope, );
    throwException(&global, scope, aggregate);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_HTMLRewriter_createHTMLRewriterError(
    EngineCallContext& context,
    const BunBindgenEngine_HTMLRewriter_createHTMLRewriterError_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* error = JSC::createError(&context.globalObject, args.message);
    RETURN_IF_EXCEPTION(scope, {});
    error->putDirect(vm, vm.propertyNames->name, JSC::jsString(vm, WTF::String("HTMLRewriterError"_s)));
    RELEASE_AND_RETURN(scope, error);
}

#define BUN_DEFINE_EXPECT_OPTIONAL_BRAND_CAST(name)                                                           \
    std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_Expect_##name(                           \
        EngineCallContext&,                                                                                  \
        const BunBindgenEngine_Expect_##name##_Arguments& args)                                               \
    {                                                                                                        \
        return args.value;                                                                                   \
    }

BUN_DEFINE_EXPECT_OPTIONAL_BRAND_CAST(tryCastObjectValue)
BUN_DEFINE_EXPECT_OPTIONAL_BRAND_CAST(tryCastCallableValue)

#undef BUN_DEFINE_EXPECT_OPTIONAL_BRAND_CAST

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_Expect_customMatcherPass(
    EngineCallContext&,
    const BunBindgenEngine_Expect_customMatcherPass_Arguments& args)
{
    return args.value;
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_Expect_customMatcherMessage(
    EngineCallContext&,
    const BunBindgenEngine_Expect_customMatcherMessage_Arguments& args)
{
    return args.value;
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_AsyncModule_createError(
    EngineCallContext& context,
    const BunBindgenEngine_AsyncModule_createError_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* error = JSC::createError(&context.globalObject, args.data.message);
    RETURN_IF_EXCEPTION(scope, {});

    if (args.data.url) {
        error->putDirect(vm, JSC::Identifier::fromString(vm, "url"_s), JSC::jsString(vm, *args.data.url));
        RETURN_IF_EXCEPTION(scope, {});
    }
    error->putDirect(vm, vm.propertyNames->name, JSC::jsString(vm, args.data.name));
    RETURN_IF_EXCEPTION(scope, {});
    error->putDirect(vm, JSC::Identifier::fromString(vm, "pkg"_s), JSC::jsString(vm, args.data.pkg));
    RETURN_IF_EXCEPTION(scope, {});
    error->putDirect(vm, JSC::Identifier::fromString(vm, "specifier"_s), JSC::jsString(vm, args.data.specifier));
    RETURN_IF_EXCEPTION(scope, {});
    error->putDirect(vm, vm.propertyNames->sourceURL, JSC::jsString(vm, args.data.source_url));
    RETURN_IF_EXCEPTION(scope, {});
    error->putDirect(vm, vm.propertyNames->line, JSC::jsNumber(args.data.line));
    if (args.data.line_text) {
        error->putDirect(vm, JSC::Identifier::fromString(vm, "lineText"_s), JSC::jsString(vm, *args.data.line_text));
        RETURN_IF_EXCEPTION(scope, {});
    }
    error->putDirect(vm, vm.propertyNames->column, JSC::jsNumber(args.data.column));
    if (args.data.referrer) {
        error->putDirect(vm, JSC::Identifier::fromString(vm, "referrer"_s), JSC::jsString(vm, *args.data.referrer));
        RETURN_IF_EXCEPTION(scope, {});
    }
    RELEASE_AND_RETURN(scope, error);
}

// Walk a promise's reaction chain to find the async generators awaiting it,
// and collect them as async StackFrames. Used when an error is created from
// native code at the top of the event loop (e.g. runFromJSThread in node_fs.zig)
// where there's no JS call stack, but the promise being rejected has an await
// chain that tells us where the user's code is.
//
// This replicates the minimal chain-walking from JSC's private
// Interpreter::getAsyncStackTrace for the common case (direct await). Promise
// combinators (all/race/any) are not traced through — we stop at them.
static void collectAsyncStackFramesFromPromise(JSC::VM& vm, JSC::JSCell* owner, JSC::JSPromise* promise, WTF::Vector<JSC::StackFrame>& results, size_t maxStackSize)
{
    if (!JSC::Options::useAsyncStackTrace() || !promise)
        return;

    JSC::AssertNoGC assertNoGC;

    auto dynamicCastValue = []<typename T>(JSC::JSValue v, T** out) -> bool {
        if (!v || !v.isCell())
            return false;
        *out = dynamicDowncast<T>(v.asCell());
        return *out != nullptr;
    };

    auto unwrapGeneratorFromContext = [&](JSC::JSValue context) -> JSC::JSAsyncFunctionGenerator* {
        JSC::InternalFieldTuple* tuple = nullptr;
        if (dynamicCastValue(context, &tuple))
            context = tuple->getInternalField(0);
        JSC::JSAsyncFunctionGenerator* generator = nullptr;
        dynamicCastValue(context, &generator);
        return generator;
    };

    // Walk reaction->context → generator. If context is not a generator (e.g.
    // thenable-chain from `return promise` without await inside an async
    // function), follow reaction->promise() to the next promise in the chain.
    // Cap hops to avoid pathological chains.
    auto getAwaitingGenerator = [&](JSC::JSPromise* p) -> JSC::JSAsyncFunctionGenerator* {
        for (unsigned hops = 0; p && hops < 32; hops++) {
            if (p->status() != JSC::JSPromise::Status::Pending)
                return nullptr;
            switch (p->inlineReactionKind()) {
            case JSC::JSPromise::InlineReactionKind::InternalMicrotask: {
                if (auto* generator = unwrapGeneratorFromContext(p->inlineReactionContext()))
                    return generator;
                if (auto* next = dynamicDowncast<JSC::JSPromise>(p->payloadCell())) {
                    p = next;
                    continue;
                }
                return nullptr;
            }
            case JSC::JSPromise::InlineReactionKind::FulfillHandler:
            case JSC::JSPromise::InlineReactionKind::RejectHandler:
                p = p->inlineHandlerResultPromise();
                continue;
            case JSC::JSPromise::InlineReactionKind::None:
                break;
            }
            auto* reaction = dynamicDowncast<JSC::JSPromiseReaction>(p->payloadCell());
            if (!reaction)
                return nullptr;
            if (auto* generator = unwrapGeneratorFromContext(JSC::JSPromiseReaction::tryGetContext(reaction)))
                return generator;
            // No generator in context — follow the thenable chain to the
            // promise this reaction resolves/rejects.
            if (!dynamicCastValue(reaction->promise(), &p))
                return nullptr;
        }
        return nullptr;
    };

    auto computeBytecodeIndex = [&](JSC::CodeBlock* codeBlock, JSC::JSAsyncFunctionGenerator* generator) -> JSC::BytecodeIndex {
        JSC::BytecodeIndex bytecodeIndex(0);
        JSC::JSValue stateValue = generator->internalField(JSC::JSAsyncFunctionGenerator::Field::State).get();
        if (stateValue.isInt32()) {
            int32_t state = stateValue.asInt32();
            size_t numberOfJumpTables = codeBlock->numberOfUnlinkedSwitchJumpTables();
            if (state > 0 && numberOfJumpTables > 0) {
                size_t lastTableIndex = numberOfJumpTables - 1;
                const JSC::UnlinkedSimpleJumpTable& jumpTable = codeBlock->unlinkedSwitchJumpTable(lastTableIndex);
                int32_t offset = jumpTable.offsetForValue(state);
                if (offset)
                    bytecodeIndex = JSC::BytecodeIndex(offset);
            }
        }
        return bytecodeIndex;
    };

    auto appendFrame = [&](JSC::JSAsyncFunctionGenerator* generator) {
        JSC::JSFunction* asyncFunction = nullptr;
        if (!dynamicCastValue(generator->next(), &asyncFunction))
            return;
        if (asyncFunction->isHostOrPrivateBuiltinFunction())
            return;
        JSC::FunctionExecutable* executable = asyncFunction->jsExecutable();
        if (!executable)
            return;
        if (JSC::CodeBlock* codeBlock = executable->codeBlockForCall()) {
            JSC::BytecodeIndex bytecodeIndex = computeBytecodeIndex(codeBlock, generator);
            results.append(JSC::StackFrame(vm, owner, asyncFunction, codeBlock, bytecodeIndex, /* isAsyncFrame */ true));
        } else {
            results.append(JSC::StackFrame(vm, owner, asyncFunction, /* isAsyncFrame */ true));
        }
    };

    JSC::JSAsyncFunctionGenerator* gen = getAwaitingGenerator(promise);
    while (gen && results.size() < maxStackSize) {
        appendFrame(gen);
        JSC::JSPromise* returnPromise = nullptr;
        if (!dynamicCastValue(gen->context(), &returnPromise))
            break;
        gen = getAwaitingGenerator(returnPromise);
    }
}

void Bun::attachAsyncStackFromPromise(JSC::JSGlobalObject* globalObject, JSC::JSValue error, JSC::JSPromise* promise)
{
    auto& vm = globalObject->vm();
    auto* instance = dynamicDowncast<JSC::ErrorInstance>(error);
    if (!instance || !promise)
        return;

    // Don't overwrite an existing stack trace. User-provided errors (e.g. via
    // StreamError.JSValue or Body.ValueError.JSValue) may already have a
    // meaningful synchronous stack from where they were created. Also skip if
    // .stack was already accessed — setStackFrames after materialization
    // would desync m_stackTrace from the cached property.
    if (instance->hasMaterializedErrorInfo() || instance->isMaterializingErrorInfo())
        return;
    if (auto* existing = instance->stackTrace(); existing && !existing->isEmpty())
        return;

    size_t limit = globalObject->stackTraceLimit().value_or(10);
    if (!limit)
        return;

    WTF::Vector<JSC::StackFrame> frames;
    collectAsyncStackFramesFromPromise(vm, instance, promise, frames, limit);
    if (frames.isEmpty())
        return;

    instance->setStackFrames(vm, WTF::move(frames));
}

void Bun::Bindgen::Engine::bunBindgenEngine_errors_attachAsyncStackFromPromise(
    EngineCallContext& context,
    const BunBindgenEngine_errors_attachAsyncStackFromPromise_Arguments& args)
{
    auto* promise = dynamicDowncast<JSC::JSPromise>(args.promise);
    RELEASE_ASSERT(promise);
    Bun::attachAsyncStackFromPromise(&context.globalObject, args.error, promise);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_errors_systemErrorToErrorInstance(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_errors_systemErrorToErrorInstance_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto& names = WebCore::builtinNames(vm);
    JSC::JSObject* result = createError(globalObject, ErrorType::Error, args.message);
    RETURN_IF_EXCEPTION(scope, {});
    auto clientData = WebCore::clientData(vm);

    if (!args.code.isEmpty())
        result->putDirect(vm, clientData->builtinNames().codePublicName(), jsString(vm, args.code), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});

    if (!args.path.isEmpty())
        result->putDirect(vm, clientData->builtinNames().pathPublicName(), jsString(vm, args.path), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});

    if (!args.dest.isEmpty())
        result->putDirect(vm, clientData->builtinNames().destPublicName(), jsString(vm, args.dest), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});

    if (args.fd >= 0)
        result->putDirect(vm, names.fdPublicName(), jsNumber(args.fd), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});

    if (!args.syscall.isEmpty())
        result->putDirect(vm, names.syscallPublicName(), jsString(vm, args.syscall), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});

    if (!args.hostname.isEmpty())
        result->putDirect(vm, names.hostnamePublicName(), jsString(vm, args.hostname), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});

    if (!args.address.isEmpty())
        result->putDirect(vm, JSC::Identifier::fromString(vm, "address"_s), jsString(vm, args.address));
    RETURN_IF_EXCEPTION(scope, {});
    if (args.port)
        result->putDirect(vm, JSC::Identifier::fromString(vm, "port"_s), jsNumber(*args.port));
    RETURN_IF_EXCEPTION(scope, {});

    result->putDirect(vm, names.errnoPublicName(), jsNumber(args.errorNumber), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});

    RELEASE_AND_RETURN(scope, result);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_errors_dnsErrorToErrorInstance(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_errors_dnsErrorToErrorInstance_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto& names = WebCore::builtinNames(vm);
    auto clientData = WebCore::clientData(vm);
    JSC::JSObject* result = createError(globalObject, ErrorType::Error, args.data.message);
    RETURN_IF_EXCEPTION(scope, {});

    result->putDirect(vm, vm.propertyNames->name, jsString(vm, String("DNSException"_s)), JSC::PropertyAttribute::DontEnum | 0);
    RETURN_IF_EXCEPTION(scope, {});
    result->putDirect(vm, clientData->builtinNames().codePublicName(), jsString(vm, args.data.code), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});
    result->putDirect(vm, names.errnoPublicName(), jsNumber(args.data.errorNumber), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});
    result->putDirect(vm, names.syscallPublicName(), jsString(vm, args.data.syscall), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});
    if (args.data.hostname)
        result->putDirect(vm, names.hostnamePublicName(), jsString(vm, *args.data.hostname), JSC::PropertyAttribute::DontDelete | 0);
    RETURN_IF_EXCEPTION(scope, {});

    RELEASE_AND_RETURN(scope, result);
}

void Bun::Bindgen::Engine::bunBindgenEngine_errors_throwStackOverflow(
    EngineCallContext& context,
    const BunBindgenEngine_errors_throwStackOverflow_Arguments&)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RETURN_IF_EXCEPTION(scope, );
    throwStackOverflowError(&context.globalObject, scope);
}
