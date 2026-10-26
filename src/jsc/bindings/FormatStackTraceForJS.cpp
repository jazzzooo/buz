#include "root.h"

#include "FormatStackTraceForJS.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include "helpers.h"

#include "JavaScriptCore/ArgList.h"
#include "JavaScriptCore/CallData.h"
#include "JavaScriptCore/Error.h"
#include "JavaScriptCore/ErrorInstance.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "JavaScriptCore/GetterSetter.h"
#include "JavaScriptCore/JSArray.h"
#include "JavaScriptCore/JSCast.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSObject.h"
#include "JavaScriptCore/JSString.h"
#include "JavaScriptCore/PropertyDescriptor.h"
#include "JavaScriptCore/StackFrame.h"
#include "JavaScriptCore/VM.h"

#include "BunClientData.h"
#include "CallSite.h"
#include "ErrorStackFrame.h"
#include "ErrorStackTrace.h"
#include <wtf/SetForScope.h>
#include <wtf/text/MakeString.h>

using namespace JSC;
using namespace WebCore;

namespace Bun {

static String formatCallSites(JSC::VM& vm, JSC::JSGlobalObject* lexicalGlobalObject, JSC::JSObject* errorObject, JSC::JSArray* callSites)
{
    auto scope = DECLARE_THROW_SCOPE(vm);

    size_t framesCount = callSites->length();

    WTF::StringBuilder sb(OverflowPolicy::RecordOverflow);

    auto errorMessage = errorObject->getIfPropertyExists(lexicalGlobalObject, vm.propertyNames->message);
    RETURN_IF_EXCEPTION(scope, {});
    if (errorMessage) {
        auto* str = errorMessage.toString(lexicalGlobalObject);
        RETURN_IF_EXCEPTION(scope, {});
        if (str->length() > 0) {
            auto value = str->view(lexicalGlobalObject);
            RETURN_IF_EXCEPTION(scope, {});
            sb.append("Error: "_s);
            sb.append(value.data);
        } else {
            sb.append("Error"_s);
        }
    } else {
        sb.append("Error"_s);
    }

    for (size_t i = 0; i < framesCount; i++) {
        sb.append("\n    at "_s);
        if (sb.hasOverflowed()) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }

        JSC::JSValue callSiteValue = callSites->getIndex(lexicalGlobalObject, i);
        RETURN_IF_EXCEPTION(scope, {});

        if (CallSite* callSite = dynamicDowncast<CallSite>(callSiteValue)) {
            callSite->formatAsString(vm, lexicalGlobalObject, sb);
            RETURN_IF_EXCEPTION(scope, {});
        } else {
            // This matches Node.js / V8's behavior
            // It can become "at [object Object]" if the object is not a CallSite
            auto* str = callSiteValue.toString(lexicalGlobalObject);
            RETURN_IF_EXCEPTION(scope, {});
            auto value = str->value(lexicalGlobalObject);
            RETURN_IF_EXCEPTION(scope, {});
            sb.append(value.data);
        }
    }

    if (sb.hasOverflowed()) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    auto result = tryMakeString(StringView(sb));
    if (result.isNull())
        throwOutOfMemoryError(lexicalGlobalObject, scope);
    return result;
}

class RecursiveStackAccessorScope {
public:
    RecursiveStackAccessorScope(JSGlobalObject* globalObject, JSObject* errorObject, GetterSetter* accessor, bool* stackPropertyChanged)
        : m_globalObject(globalObject)
        , m_errorObject(errorObject)
        , m_accessor(accessor)
        , m_stackPropertyChanged(stackPropertyChanged)
        , m_original(errorObject->getDirect(globalObject->vm(), globalObject->vm().propertyNames->stack, m_originalAttributes))
    {
        m_errorObject->putDirectNonIndexAccessor(globalObject->vm(), globalObject->vm().propertyNames->stack, accessor, PropertyAttribute::Accessor | PropertyAttribute::DontEnum);
    }

    ~RecursiveStackAccessorScope()
    {
        auto& vm = m_globalObject->vm();
        unsigned attributes = 0;
        auto current = m_errorObject->getDirect(vm, vm.propertyNames->stack, attributes);
        if (current != m_accessor || attributes != (PropertyAttribute::Accessor | PropertyAttribute::DontEnum)) {
            if (m_stackPropertyChanged)
                *m_stackPropertyChanged = true;
            if (auto* error = dynamicDowncast<ErrorInstance>(m_errorObject))
                error->setStackPropertyAlreadyMaterialized();
            return;
        }

        if (m_originalAttributes & PropertyAttribute::Accessor)
            m_errorObject->putDirectNonIndexAccessor(vm, vm.propertyNames->stack, uncheckedDowncast<GetterSetter>(m_original), m_originalAttributes);
        else if (m_originalAttributes & PropertyAttribute::CustomAccessorOrValue)
            m_errorObject->putDirectCustomAccessor(vm, vm.propertyNames->stack, m_original, m_originalAttributes);
        else if (m_original)
            m_errorObject->putDirect(vm, vm.propertyNames->stack, m_original, m_originalAttributes);
        else {
            DeletePropertySlot slot;
            JSObject::deleteProperty(m_errorObject, m_globalObject, vm.propertyNames->stack, slot);
        }
    }

private:
    JSGlobalObject* m_globalObject;
    JSObject* m_errorObject;
    GetterSetter* m_accessor;
    bool* m_stackPropertyChanged;
    unsigned m_originalAttributes = 0;
    JSValue m_original;
};

static JSValue formatStackTraceToJSValue(JSC::VM& vm, Zig::GlobalObject* globalObject, JSC::JSGlobalObject* lexicalGlobalObject, JSC::JSObject* errorObject, JSC::JSArray* callSites, JSValue prepareStackTrace, bool* stackPropertyChanged)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto callData = JSC::getCallData(prepareStackTrace);
    RELEASE_ASSERT(callData.type != JSC::CallData::Type::None);

    MarkedArgumentBuffer arguments;
    arguments.append(errorObject);
    arguments.append(callSites);
    if (arguments.hasOverflowed()) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }

    auto factory = bun_bindgen_source_function_RuntimeFunctions_createRecursiveStackAccessor_value(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto accessors = profiledCall(lexicalGlobalObject, ProfilingReason::Other, factory, getCallData(factory), jsUndefined(), arguments);
    RETURN_IF_EXCEPTION(scope, {});
    auto* accessor = uncheckedDowncast<GetterSetter>(asObject(accessors)->getDirect(vm, vm.propertyNames->stack));
    RecursiveStackAccessorScope recursiveStack(lexicalGlobalObject, errorObject, accessor, stackPropertyChanged);
    RETURN_IF_EXCEPTION(scope, {});

    RELEASE_AND_RETURN(scope, profiledCall(
        lexicalGlobalObject, ProfilingReason::Other, prepareStackTrace, callData,
        lexicalGlobalObject->m_errorStructure.constructor(lexicalGlobalObject), arguments));
}

WTF::String formatStackTrace(
    JSC::VM& vm,
    Zig::GlobalObject* globalObject,
    JSC::JSGlobalObject* lexicalGlobalObject,
    const WTF::String& name,
    const WTF::String& message,
    OrdinalNumber& line,
    OrdinalNumber& column,
    WTF::String& sourceURL,
    Vector<JSC::StackFrame>& stackTrace,
    JSC::JSObject* errorInstance)
{
    WTF::StringBuilder sb;

    if (!name.isEmpty()) {
        sb.append(name);
        if (!message.isEmpty()) {
            sb.append(": "_s);
            sb.append(message);
        }
    } else if (!message.isEmpty()) {
        sb.append(message);
    }

    size_t framesCount = stackTrace.size();

    bool hasSet = false;
    VirtualMachine* bunVM = nullptr;
    const auto getBunVM = [&]() -> VirtualMachine* {
        if (!bunVM) {
            bunVM = clientData(vm)->bunVM;
        }
        return bunVM;
    };

    if (errorInstance) {
        if (JSC::ErrorInstance* err = dynamicDowncast<JSC::ErrorInstance>(errorInstance)) {
            if (err->errorType() == ErrorType::SyntaxError && (stackTrace.isEmpty() || stackTrace.at(0).sourceURL(vm) != err->sourceURL())) {
                // There appears to be an off-by-one error.
                // The following reproduces the issue:
                // /* empty comment */
                // "".test(/[a-0]/);
                auto originalLine = WTF::OrdinalNumber::fromOneBasedInt(err->line());

                Bun::RemappableStackFrame remappedFrame;

                remappedFrame.position.lineZeroBased = originalLine.zeroBasedInt();
                remappedFrame.position.columnZeroBased = 0;

                String sourceURLForFrame = err->sourceURL();

                // If it's not a Zig::GlobalObject, don't bother source-mapping it.
                if (globalObject && !sourceURLForFrame.isEmpty()) {
                    // https://github.com/oven-sh/bun/issues/3595
                    if (!sourceURLForFrame.isEmpty()) {
                        remappedFrame.sourceURL = sourceURLForFrame;
                        Bun::remapStackFramePosition(getBunVM(), remappedFrame);

                        sourceURLForFrame = remappedFrame.sourceURL;
                    }
                }

                // there is always a newline before each stack frame line, ensuring that the name + message
                // exist on the first line, even if both are empty
                sb.append("\n"_s);

                sb.append("    at <parse> ("_s);

                sb.append(remappedFrame.sourceURL);

                if (remappedFrame.remapped) {
                    errorInstance->putDirect(vm, builtinNames(vm).originalLinePublicName(), jsNumber(originalLine.oneBasedInt()), PropertyAttribute::DontEnum | 0);
                    hasSet = true;
                    line = remappedFrame.position.line();
                }

                if (remappedFrame.remapped) {
                    sb.append(':');
                    sb.append(remappedFrame.position.line().oneBasedInt());
                } else {
                    sb.append(':');
                    sb.append(originalLine.oneBasedInt());
                }

                sb.append(')');
            }
        }
    }

    if (framesCount == 0) {
        ASSERT(stackTrace.isEmpty());
        return sb.toString();
    }

    sb.append("\n"_s);

    // Pass 1: collect the source positions for frames that should be source-mapped.
    WTF::Vector<Bun::RemappableStackFrame, 8> remappedFrames;
    WTF::Vector<WTF::String, 8> sourceURLs;
    WTF::Vector<LineColumn, 8> originalLineColumns;
    remappedFrames.grow(framesCount);
    sourceURLs.grow(framesCount);
    originalLineColumns.grow(framesCount);
    bool anyRemap = false;

    for (size_t i = 0; i < framesCount; i++) {
        StackFrame& frame = stackTrace.at(i);
        auto& remappedFrame = remappedFrames[i];
        originalLineColumns[i] = {};

        if (!frame.hasLineAndColumnInfo()) continue;

        originalLineColumns[i] = frame.computeLineAndColumn();

        JSC::JSGlobalObject* globalObjectForFrame = lexicalGlobalObject;
        if (auto* callee = frame.callee()) {
            if (auto* object = callee->getObject()) {
                globalObjectForFrame = object->globalObject();
            }
        }

        sourceURLs[i] = Zig::sourceURL(vm, frame);

        bool isDefinitelyNotRunninginNodeVMGlobalObject = globalObject == globalObjectForFrame;
        bool isDefaultGlobalObjectInAFinalizer = (globalObject && !lexicalGlobalObject && !errorInstance);
        if (isDefinitelyNotRunninginNodeVMGlobalObject || isDefaultGlobalObjectInAFinalizer) {
            // https://github.com/oven-sh/bun/issues/3595
            if (!sourceURLs[i].isEmpty()) {
                remappedFrame.position.lineZeroBased = OrdinalNumber::fromOneBasedInt(originalLineColumns[i].line).zeroBasedInt();
                remappedFrame.position.columnZeroBased = OrdinalNumber::fromOneBasedInt(originalLineColumns[i].column).zeroBasedInt();
                remappedFrame.sourceURL = sourceURLs[i];
                anyRemap = true;
            }
        }
    }

    if (anyRemap) {
        Bun::remapStackFramePositions(getBunVM(), remappedFrames.mutableSpan());
    }

    // Pass 2: format. Everything except the display position and source URL is
    // re-derived from `frame`; only the remap output is read from pass 1.
    for (size_t i = 0; i < framesCount; i++) {
        StackFrame& frame = stackTrace.at(i);
        auto& remappedFrame = remappedFrames[i];
        unsigned int flags = static_cast<unsigned int>(FunctionNameFlags::AddNewKeyword);

        JSC::JSGlobalObject* globalObjectForFrame = lexicalGlobalObject;
        if (frame.hasLineAndColumnInfo()) {
            if (auto* callee = frame.callee()) {
                if (auto* object = callee->getObject()) {
                    globalObjectForFrame = object->globalObject();
                }
            }
        }

        WTF::String functionName = Zig::functionName(vm, globalObjectForFrame, frame, errorInstance ? Zig::FinalizerSafety::NotInFinalizer : Zig::FinalizerSafety::MustNotTriggerGC, &flags);
        OrdinalNumber originalLine = {};
        OrdinalNumber originalColumn = {};
        OrdinalNumber displayLine = {};
        OrdinalNumber displayColumn = {};
        WTF::String sourceURLForFrame = sourceURLs[i];

        if (frame.hasLineAndColumnInfo()) {
            originalLine = OrdinalNumber::fromOneBasedInt(originalLineColumns[i].line);
            originalColumn = OrdinalNumber::fromOneBasedInt(originalLineColumns[i].column);
            displayLine = originalLine;
            displayColumn = originalColumn;

            if (remappedFrame.remapped) {
                displayLine = remappedFrame.position.line();
                displayColumn = remappedFrame.position.column();
                sourceURLForFrame = remappedFrame.sourceURL;
            }

            if (!hasSet) {
                hasSet = true;
                line = displayLine;
                column = displayColumn;
                sourceURL = sourceURLForFrame;

                if (remappedFrame.remapped) {
                    if (errorInstance) {
                        errorInstance->putDirect(vm, builtinNames(vm).originalLinePublicName(), jsNumber(originalLine.oneBasedInt()), PropertyAttribute::DontEnum | 0);
                        errorInstance->putDirect(vm, builtinNames(vm).originalColumnPublicName(), jsNumber(originalColumn.oneBasedInt()), PropertyAttribute::DontEnum | 0);
                    }
                }
            }
        }

        if (functionName.isEmpty()) {
            if (flags & (static_cast<unsigned int>(FunctionNameFlags::Eval) | static_cast<unsigned int>(FunctionNameFlags::Function))) {
                functionName = "<anonymous>"_s;
            }
        }

        if (sourceURLForFrame.isEmpty()) {
            if (flags & static_cast<unsigned int>(FunctionNameFlags::Builtin)) {
                sourceURLForFrame = "native"_s;
            } else {
                sourceURLForFrame = "unknown"_s;
            }
        }

        // --- actually render the text ---

        sb.append("    at "_s);

        if (!functionName.isEmpty()) {
            if (frame.isAsyncFrame()) {
                sb.append("async "_s);
            }
            sb.append(functionName);
            sb.append(" ("_s);
        }

        if (!sourceURLForFrame.isEmpty()) {
            sb.append(sourceURLForFrame);
            if (displayLine.zeroBasedInt() > 0 || displayColumn.zeroBasedInt() > 0) {
                sb.append(':');
                sb.append(displayLine.oneBasedInt());

                if (displayColumn.zeroBasedInt() > 0) {
                    sb.append(':');
                    sb.append(displayColumn.oneBasedInt());
                }
            }
        }

        if (!functionName.isEmpty()) {
            sb.append(')');
        }

        if (i != framesCount - 1) {
            sb.append("\n"_s);
        }
    }

    return sb.toString();
}

// error.stack calls this function
static String computeErrorInfoWithoutPrepareStackTrace(
    JSC::VM& vm,
    Zig::GlobalObject* globalObject,
    JSC::JSGlobalObject* lexicalGlobalObject,
    Vector<StackFrame>& stackTrace,
    OrdinalNumber& line,
    OrdinalNumber& column,
    String& sourceURL,
    JSObject* errorInstance)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    WTF::String name = "Error"_s;
    WTF::String message;

    if (errorInstance) {
        if (auto* instance = dynamicDowncast<ErrorInstance>(errorInstance)) {
            if (!lexicalGlobalObject) {
                lexicalGlobalObject = errorInstance->globalObject();
            }
            name = instance->sanitizedNameString(lexicalGlobalObject);
            RETURN_IF_EXCEPTION(scope, {});
            message = instance->sanitizedMessageString(lexicalGlobalObject);
            RETURN_IF_EXCEPTION(scope, {});
        }
    }

    if (!globalObject) [[unlikely]] {
        globalObject = defaultGlobalObject();
    }

    return Bun::formatStackTrace(vm, globalObject, lexicalGlobalObject, name, message, line, column, sourceURL, stackTrace, errorInstance);
}

static JSValue computeErrorInfoWithPrepareStackTrace(JSC::VM& vm, Zig::GlobalObject* globalObject, JSC::JSGlobalObject* lexicalGlobalObject, Vector<StackFrame>& stackFrames, OrdinalNumber& line, OrdinalNumber& column, String& sourceURL, JSObject* errorObject, JSObject* prepareStackTrace, bool* stackPropertyChanged)
{
    auto scope = DECLARE_THROW_SCOPE(vm);

    MarkedArgumentBuffer frameRoots;
    for (const auto& frame : stackFrames) {
        if (auto* callee = frame.callee())
            frameRoots.append(callee);
        if (auto* codeBlock = frame.codeBlock())
            frameRoots.append(codeBlock);
        if (frameRoots.hasOverflowed()) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return {};
        }
    }
    MarkedArgumentBuffer callSites;
    WTF::Vector<size_t> visibleFrameIndices;

    Zig::createCallSitesFromFrames(globalObject, lexicalGlobalObject, stackFrames, callSites, visibleFrameIndices);
    RETURN_IF_EXCEPTION(scope, {});
    if (callSites.hasOverflowed()) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }

    // We need to sourcemap it if it's a GlobalObject.

    const size_t n = visibleFrameIndices.size();
    WTF::Vector<Bun::RemappableStackFrame, 8> remappedFrames;
    WTF::Vector<WTF::String, 8> sourceURLs;
    WTF::Vector<bool, 8> didRemap;
    if (!remappedFrames.tryGrow(n) || !sourceURLs.tryGrow(n) || !didRemap.tryGrow(n)) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    bool anyRemap = false;

    for (size_t i = 0; i < n; i++) {
        auto& frame = remappedFrames[i];
        auto& stackFrame = stackFrames.at(visibleFrameIndices[i]);
        sourceURLs[i] = Zig::sourceURL(vm, stackFrame);
        didRemap[i] = false;

        // When you use node:vm, the global object can be different on a
        // per-frame basis. We should sourcemap the frames which are in Bun's
        // global object, and not sourcemap the frames which are in a different
        // global object.
        JSGlobalObject* globalObjectForFrame = lexicalGlobalObject;

        if (stackFrame.hasLineAndColumnInfo()) {
            auto* callee = stackFrame.callee();
            // https://github.com/oven-sh/bun/issues/17698
            if (callee) {
                if (auto* object = callee->getObject()) {
                    globalObjectForFrame = object->globalObject();
                }
            }
        }

        if (globalObjectForFrame == globalObject) {
            auto* callSite = uncheckedDowncast<CallSite>(callSites.at(i));
            frame.position.lineZeroBased = callSite->lineNumber().zeroBasedInt();
            frame.position.columnZeroBased = callSite->columnNumber().zeroBasedInt();

            if (!sourceURLs[i].isEmpty()) {
                frame.sourceURL = sourceURLs[i];
                didRemap[i] = true;
                anyRemap = true;
            }
        }
    }

    if (anyRemap) {
        Bun::remapStackFramePositions(globalObject->bunVM(), remappedFrames.mutableSpan());
    }

    for (size_t i = 0; i < n; i++) {
        auto& frame = remappedFrames[i];
        WTF::String sourceURLForFrame = didRemap[i] ? frame.sourceURL : sourceURLs[i];

        auto* callsite = uncheckedDowncast<CallSite>(callSites.at(i));

        if (!sourceURLForFrame.isEmpty()) {
            auto* source = jsString(vm, sourceURLForFrame);
            RETURN_IF_EXCEPTION(scope, {});
            callsite->setSourceURL(vm, source);
        }

        if (frame.remapped) {
            callsite->setLineNumber(frame.position.line());
            callsite->setColumnNumber(frame.position.column());
        }
    }

    JSArray* callSitesArray = JSC::constructArray(globalObject, globalObject->arrayStructureForIndexingTypeDuringAllocation(JSC::ArrayWithContiguous), callSites);
    RETURN_IF_EXCEPTION(scope, {});

    RELEASE_AND_RETURN(scope, formatStackTraceToJSValue(vm, globalObject, lexicalGlobalObject, errorObject, callSitesArray, prepareStackTrace, stackPropertyChanged));
}

static JSValue computeErrorInfoToJSValue(JSC::VM& vm, Vector<StackFrame>& stackTrace, OrdinalNumber& line, OrdinalNumber& column, String& sourceURL, JSObject* errorInstance, bool* stackPropertyChanged = nullptr)
{
    if (stackPropertyChanged)
        *stackPropertyChanged = false;

    Zig::GlobalObject* globalObject = nullptr;
    JSC::JSGlobalObject* lexicalGlobalObject = nullptr;
    lexicalGlobalObject = errorInstance->globalObject();
    globalObject = dynamicDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!globalObject)
        globalObject = defaultGlobalObject();
    if (!globalObject->isInsideErrorPrepareStackTraceCallback) {
        SetForScope preparingStack(globalObject->isInsideErrorPrepareStackTraceCallback, true);
        auto* errorConstructor = lexicalGlobalObject->m_errorStructure.constructor(lexicalGlobalObject);
        auto prepareStackTrace = errorConstructor->getIfPropertyExists(lexicalGlobalObject, builtinNames(vm).prepareStackTracePublicName());
        RETURN_IF_EXCEPTION(scope, {});
        // The built-in formatter value selects the native default formatting path.
        bool isDefaultFormatter = lexicalGlobalObject == globalObject && prepareStackTrace == globalObject->m_errorConstructorPrepareStackTraceInternalValue.get(globalObject);
        if (prepareStackTrace && prepareStackTrace.isCallable() && !isDefaultFormatter)
            RELEASE_AND_RETURN(scope, computeErrorInfoWithPrepareStackTrace(vm, globalObject, lexicalGlobalObject, stackTrace, line, column, sourceURL, errorInstance, prepareStackTrace.getObject(), stackPropertyChanged));
    }

    String result = computeErrorInfoWithoutPrepareStackTrace(vm, globalObject, lexicalGlobalObject, stackTrace, line, column, sourceURL, errorInstance);
    RETURN_IF_EXCEPTION(scope, {});
    return jsString(vm, result);
}

WTF::String computeErrorInfoWrapperToString(JSC::VM& vm, Vector<StackFrame>& stackTrace, unsigned int& line_in, unsigned int& column_in, String& sourceURL, void* bunErrorData)
{
    UNUSED_PARAM(bunErrorData);

    OrdinalNumber line = OrdinalNumber::fromOneBasedInt(line_in);
    OrdinalNumber column = OrdinalNumber::fromOneBasedInt(column_in);

    WTF::String result = formatStackTrace(vm, defaultGlobalObject(), nullptr, "Error"_s, {}, line, column, sourceURL, stackTrace, nullptr);

    line_in = line.oneBasedInt();
    column_in = column.oneBasedInt();

    return result;
}

void computeLineColumnWithSourcemap(JSC::VM& vm, JSC::SourceProvider* _Nonnull sourceProvider, JSC::LineColumn& lineColumn, WTF::String& remappedSourceURL)
{
    auto sourceURL = sourceProvider->sourceURL();
    if (sourceURL.isEmpty()) {
        return;
    }

    OrdinalNumber line = OrdinalNumber::fromOneBasedInt(lineColumn.line);
    OrdinalNumber column = OrdinalNumber::fromOneBasedInt(lineColumn.column);

    Bun::RemappableStackFrame frame;
    frame.position.lineZeroBased = line.zeroBasedInt();
    frame.position.columnZeroBased = column.zeroBasedInt();
    frame.sourceURL = sourceURL;

    Bun::remapStackFramePosition(Bun::vm(vm), frame);

    if (frame.remapped) {
        lineColumn.line = frame.position.line().oneBasedInt();
        lineColumn.column = frame.position.column().oneBasedInt();
        remappedSourceURL = frame.sourceURL;
    }
}

JSC::JSValue computeErrorInfoWrapperToJSValue(JSC::VM& vm, Vector<StackFrame>& stackTrace, unsigned int& line_in, unsigned int& column_in, String& sourceURL, JSObject* errorInstance, void* bunErrorData)
{
    UNUSED_PARAM(bunErrorData);
    auto scope = DECLARE_THROW_SCOPE(vm);
    OrdinalNumber line = OrdinalNumber::fromOneBasedInt(line_in);
    OrdinalNumber column = OrdinalNumber::fromOneBasedInt(column_in);
    String formattedSourceURL = sourceURL;

    JSValue result = computeErrorInfoToJSValue(vm, stackTrace, line, column, formattedSourceURL, errorInstance);
    RETURN_IF_EXCEPTION(scope, {});

    line_in = line.oneBasedInt();
    column_in = column.oneBasedInt();
    sourceURL = WTF::move(formattedSourceURL);

    return result;
}

} // namespace Bun

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_errorConstructorFuncAppendStackTrace(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_errorConstructorFuncAppendStackTrace_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    const std::optional<JSC::JSValue>& sourceInput = args.source;
    const std::optional<JSC::JSValue>& destinationInput = args.destination;
    Zig::GlobalObject* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* source = sourceInput ? dynamicDowncast<JSC::ErrorInstance>(*sourceInput) : nullptr;
    auto* destination = destinationInput ? dynamicDowncast<JSC::ErrorInstance>(*destinationInput) : nullptr;

    if (!source || !destination) {
        throwTypeError(lexicalGlobalObject, scope, "First & second argument must be an Error object"_s);
        return;
    }
    if (source == destination)
        return;

    MarkedArgumentBuffer sourceRoots;
    if (auto* frames = source->stackTrace()) {
        for (const auto& frame : *frames) {
            if (auto* callee = frame.callee())
                sourceRoots.append(callee);
            if (auto* codeBlock = frame.codeBlock())
                sourceRoots.append(codeBlock);
            if (sourceRoots.hasOverflowed()) {
                throwOutOfMemoryError(lexicalGlobalObject, scope);
                return;
            }
        }
    }

    if (!destination->stackTrace()) {
        destination->captureStackTrace(vm, globalObject, 1);
        RETURN_IF_EXCEPTION(scope, void());
    }

    if (source->stackTrace()) {
        bool appended;
        {
            Locker locker { destination->cellLock() };
            appended = destination->stackTrace()->tryAppend(source->stackTrace()->span());
        }
        if (!appended) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return;
        }
        {
            Locker locker { source->cellLock() };
            source->stackTrace()->clear();
        }
        vm.writeBarrier(destination);
    }

}

WTF::String Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsFunctionDefaultErrorPrepareStackTrace(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_jsFunctionDefaultErrorPrepareStackTrace_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto* callSites = args.callSites ? uncheckedDowncast<JSC::JSArray>(*args.callSites) : nullptr;
    if (!callSites)
        callSites = JSArray::create(vm, globalObject->arrayStructureForIndexingTypeDuringAllocation(JSC::ArrayWithContiguous), 0);
    return Bun::formatCallSites(vm, globalObject, JSC::asObject(args.error), callSites);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_errorConstructorFuncCaptureStackTrace(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_errorConstructorFuncCaptureStackTrace_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    JSC::JSObject* errorObject = JSC::asObject(args.target);
    JSC::JSValue caller = args.caller;
    Zig::GlobalObject* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    bool extensible = errorObject->isExtensible(lexicalGlobalObject);
    RETURN_IF_EXCEPTION(scope, void());
    if (!extensible) {
        throwTypeError(lexicalGlobalObject, scope, "Cannot define property stack, object is not extensible"_s);
        return;
    }

    auto* instance = dynamicDowncast<JSC::ErrorInstance>(errorObject);
    bool configurable = true;
    if (instance) {
        unsigned attributes = 0;
        if (instance->getDirect(vm, vm.propertyNames->stack, attributes))
            configurable = !(attributes & PropertyAttribute::DontDelete);
    } else {
        PropertyDescriptor descriptor;
        if (errorObject->getOwnPropertyDescriptor(lexicalGlobalObject, vm.propertyNames->stack, descriptor))
            configurable = descriptor.configurable();
        RETURN_IF_EXCEPTION(scope, void());
    }
    if (!configurable) {
        throwTypeError(lexicalGlobalObject, scope, "Cannot redefine property: stack"_s);
        return;
    }

    size_t stackTraceLimit = globalObject->stackTraceLimit().value_or(DEFAULT_ERROR_STACK_TRACE_LIMIT);

    WTF::Vector<JSC::StackFrame> stackTrace;
    Zig::getFramesForCaller(vm, errorObject, caller, stackTrace, stackTraceLimit);
    RETURN_IF_EXCEPTION(scope, void());

    if (instance) {
        if (instance->hasMaterializedErrorInfo() || instance->isMaterializingErrorInfo()) {
            // Error info was already materialized (e.g. .stack was previously accessed).
            // Don't call setStackFrames — it would leave m_errorInfoMaterialized=true with
            // a non-null m_stackTrace, causing ASSERT(!m_errorInfoMaterialized) in
            // computeErrorInfo when GC's finalizeUnconditionally finds unmarked frames.
            // Eagerly compute and set the .stack property instead.
            OrdinalNumber line;
            OrdinalNumber column;
            String sourceURL;
            bool stackPropertyChanged;
            JSValue result = computeErrorInfoToJSValue(vm, stackTrace, line, column, sourceURL, errorObject, &stackPropertyChanged);
            RETURN_IF_EXCEPTION(scope, void());
            if (!stackPropertyChanged) {
                PropertyDescriptor descriptor(result, static_cast<unsigned>(PropertyAttribute::DontEnum));
                errorObject->methodTable()->defineOwnProperty(errorObject, lexicalGlobalObject, vm.propertyNames->stack, descriptor, true);
                RETURN_IF_EXCEPTION(scope, void());
            }
        } else {
            DeletePropertySlot slot;
            bool deleted = JSObject::deleteProperty(instance, globalObject, vm.propertyNames->stack, slot);
            RETURN_IF_EXCEPTION(scope, void());
            if (!deleted) {
                throwTypeError(lexicalGlobalObject, scope, "Cannot redefine property: stack"_s);
                return;
            }
            instance->setStackFrames(vm, WTF::move(stackTrace));
        }
    } else {
        OrdinalNumber line;
        OrdinalNumber column;
        String sourceURL;
        bool stackPropertyChanged;
        JSValue result = computeErrorInfoToJSValue(vm, stackTrace, line, column, sourceURL, errorObject, &stackPropertyChanged);
        RETURN_IF_EXCEPTION(scope, void());
        if (!stackPropertyChanged) {
            PropertyDescriptor descriptor(result, static_cast<unsigned>(PropertyAttribute::DontEnum));
            errorObject->methodTable()->defineOwnProperty(errorObject, lexicalGlobalObject, vm.propertyNames->stack, descriptor, true);
            RETURN_IF_EXCEPTION(scope, void());
        }
    }
}

namespace Zig {

void createCallSitesFromFrames(Zig::GlobalObject* globalObject, JSC::JSGlobalObject* lexicalGlobalObject, const WTF::Vector<JSC::StackFrame>& stackTrace, MarkedArgumentBuffer& callSites, WTF::Vector<size_t>& visibleFrameIndices)
{
    auto& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    /* From v8's "Stack Trace API" (https://github.com/v8/v8/wiki/Stack-Trace-API):
     * "To maintain restrictions imposed on strict mode functions, frames that have a
     * strict mode function and all frames below (its caller etc.) are not allow to access
     * their receiver and function objects. For those frames, getFunction() and getThis()
     * will return undefined."." */
    bool encounteredStrictFrame = false;

    // TODO: is it safe to use CallSite structure from a different JSGlobalObject? This case would happen within a node:vm
    JSC::Structure* callSiteStructure = globalObject->callSiteStructure();
    RETURN_IF_EXCEPTION(scope, void());
    size_t framesCount = stackTrace.size();
    if (!visibleFrameIndices.tryReserveInitialCapacity(framesCount)) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return;
    }

    for (size_t i = 0; i < framesCount; i++) {
        if (isImplementationVisibilityPrivate(stackTrace.at(i)))
            continue;
        JSCStackFrame frame(vm, stackTrace.at(i));
        CallSite* callSite = CallSite::create(lexicalGlobalObject, callSiteStructure, frame, encounteredStrictFrame);
        RETURN_IF_EXCEPTION(scope, void());

        if (!encounteredStrictFrame) {
            encounteredStrictFrame = callSite->isStrict();
        }

        callSites.append(callSite);
        if (callSites.hasOverflowed()) {
            throwOutOfMemoryError(lexicalGlobalObject, scope);
            return;
        }
        visibleFrameIndices.append(i);
    }
}

} // namespace Zig
