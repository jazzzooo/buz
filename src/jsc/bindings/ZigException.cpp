#include "root.h"

#include "JavaScriptCore/ErrorType.h"
#include "JavaScriptCore/TopExceptionScope.h"
#include "JavaScriptCore/Exception.h"
#include "SchemaBindingsErrorCodes.h"
#include "ErrorCode.h"
#include "JavaScriptCore/ThrowScope.h"

#include "JavaScriptCore/JSCast.h"
#include "JavaScriptCore/JSType.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSGlobalObject.h"
#include "SchemaBindings.h"

#include "BunClientData.h"
#include "WebCoreJSBuiltins.h"

#include "JavaScriptCore/BytecodeIndex.h"
#include "JavaScriptCore/CodeBlock.h"
#include "JavaScriptCore/ErrorInstance.h"
#include "JavaScriptCore/ErrorInstanceInlines.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "JavaScriptCore/JSObject.h"
#include "JavaScriptCore/JSString.h"
#include "JavaScriptCore/StackFrame.h"
#include "JavaScriptCore/VM.h"
#include "ZigGlobalObject.h"
#include "helpers.h"
#include "JavaScriptCore/JSObjectInlines.h"

#include "wtf/Assertions.h"
#include "wtf/text/OrdinalNumber.h"
#include "wtf/text/StringView.h"
#include "wtf/text/MakeString.h"
#include "wtf/text/WTFString.h"
#include "wtf/text/StringToIntegerConversion.h"

#include "ErrorStackFrame.h"
#include "ErrorStackTrace.h"
#include "ObjectBindings.h"

#include <JavaScriptCore/VMInlines.h>
#include "wtf-bindings.h"

static WTF::StringView StringView_slice(WTF::StringView sv, unsigned start, unsigned end)
{
    return sv.substring(start, end - start);
}

using namespace JSC;
using namespace WebCore;

using DiagnosticFrame = Bun::Bindgen::ExceptionStackFrameResult;
using DiagnosticDetails = Bun::Bindgen::ExceptionDetailsResult;
using DiagnosticSnapshot = Bun::Bindgen::ExceptionSnapshotResult;
using DiagnosticSourceLine = Bun::Bindgen::ExceptionSourceLineResult;
using DiagnosticErrorCode = Bun::Bindgen::ExceptionErrorCode;
using Zig::FinalizerSafety;

static DiagnosticDetails emptyDiagnosticDetails()
{
    DiagnosticDetails result {};
    result.errorCode = DiagnosticErrorCode::unknown;
    result.runtimeType = Bun::Bindgen::ExceptionRuntimeType::nothing;
    return result;
}

static DiagnosticErrorCode diagnosticErrorCode(const JSC::ErrorInstance& error)
{
    if (error.isStackOverflowError())
        return DiagnosticErrorCode::stack_overflow;
    if (error.isOutOfMemoryError())
        return DiagnosticErrorCode::out_of_memory;
    switch (error.errorType()) {
    case JSC::ErrorType::Error:
        return DiagnosticErrorCode::generic_error;
    case JSC::ErrorType::EvalError:
        return DiagnosticErrorCode::eval_error;
    case JSC::ErrorType::RangeError:
        return DiagnosticErrorCode::range_error;
    case JSC::ErrorType::ReferenceError:
        return DiagnosticErrorCode::reference_error;
    case JSC::ErrorType::SyntaxError:
        return DiagnosticErrorCode::syntax_error;
    case JSC::ErrorType::TypeError:
        return DiagnosticErrorCode::type_error;
    case JSC::ErrorType::URIError:
        return DiagnosticErrorCode::uri_error;
    case JSC::ErrorType::AggregateError:
        return DiagnosticErrorCode::aggregate_error;
    case JSC::ErrorType::SuppressedError:
        return DiagnosticErrorCode::suppressed_error;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static bool clearRecoverableDiagnosticException(JSC::TopExceptionScope& scope)
{
    if (auto* exception = scope.exception()) {
        if (auto* error = dynamicDowncast<JSC::ErrorInstance>(exception->value()); error && error->isOutOfMemoryError())
            return false;
    }
    return scope.clearExceptionExceptTermination();
}

static void throwDiagnosticOutOfMemory(JSC::JSGlobalObject& global)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    JSC::throwOutOfMemoryError(&global, scope);
}

static WTF::String copyDiagnosticText(JSC::JSGlobalObject& globalObject, WTF::StringView text)
{
    auto result = WTF::tryMakeString(text);
    if (result.isNull()) {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        JSC::throwOutOfMemoryError(&globalObject, scope);
    }
    return result;
}

static void populateStackFrameMetadata(JSC::VM& vm, JSC::JSGlobalObject* globalObject, const JSC::StackFrame& stackFrame, DiagnosticFrame& frame, FinalizerSafety finalizerSafety)
{
    if (stackFrame.isWasmFrame()) {
        frame.codeType = Bun::Bindgen::ExceptionStackFrameCode::wasm;

        auto name = Zig::functionName(vm, globalObject, stackFrame, finalizerSafety, nullptr);
        if (!name.isEmpty()) {
            frame.functionName = WTF::move(name);
        }

        auto sourceURL = Zig::sourceURL(vm, stackFrame);
        if (sourceURL != "[wasm code]"_s) {
            // [wasm code] is a useless source URL, so we don't bother to set it.
            // It is the default value JSC returns.
            frame.sourceURL = WTF::move(sourceURL);
        }
        return;
    }

    auto sourceURL = Zig::sourceURL(vm, stackFrame);
    frame.sourceURL = WTF::move(sourceURL);
    auto m_codeBlock = stackFrame.codeBlock();
    if (m_codeBlock) {
        switch (m_codeBlock->codeType()) {
        case JSC::EvalCode: {
            frame.codeType = Bun::Bindgen::ExceptionStackFrameCode::eval;
            return;
        }
        case JSC::ModuleCode: {
            frame.codeType = Bun::Bindgen::ExceptionStackFrameCode::module;
            return;
        }
        case JSC::GlobalCode: {
            frame.codeType = Bun::Bindgen::ExceptionStackFrameCode::global;
            return;
        }
        case JSC::FunctionCode: {
            frame.codeType = !m_codeBlock->isConstructor() ? Bun::Bindgen::ExceptionStackFrameCode::function : Bun::Bindgen::ExceptionStackFrameCode::constructor;
            break;
        }
        default:
            ASSERT_NOT_REACHED();
        }
    }

    WTF::String functionName;
    if (finalizerSafety == FinalizerSafety::MustNotTriggerGC) {
        // Use the safe overload that avoids property access
        functionName = Zig::functionName(vm, globalObject, stackFrame, finalizerSafety, nullptr);
    } else {
        // Use the richer callee-based path
        if (auto calleeCell = stackFrame.callee()) {
            if (auto* callee = calleeCell->getObject())
                functionName = Zig::functionName(vm, globalObject, callee);
        }
    }
    if (!functionName.isEmpty())
        frame.functionName = WTF::move(functionName);

    frame.isAsync = stackFrame.isAsyncFrame();
}

static void populateStackFramePosition(const JSC::StackFrame& stackFrame, DiagnosticFrame& frame)
{
    auto* code = stackFrame.codeBlock();
    if (!code || !code->source().provider() || code->source().provider()->source().isNull())
        return;
    if (!stackFrame.hasBytecodeIndex()) {
        if (stackFrame.hasLineAndColumnInfo()) {
            auto location = stackFrame.computeLineAndColumn();
            frame.line = Bun::knownStackIndex(OrdinalNumber::fromOneBasedInt(location.line).zeroBasedInt());
            frame.column = Bun::knownStackIndex(OrdinalNumber::fromOneBasedInt(location.column).zeroBasedInt());
        }
        return;
    }
    auto location = Bun::getAdjustedPositionForBytecode(code, stackFrame.bytecodeIndex());
    frame.line = Bun::knownStackIndex(location.lineZeroBased);
    frame.column = Bun::knownStackIndex(location.columnZeroBased);
    frame.bytePosition = Bun::knownStackIndex(location.bytePosition);
}

static bool isVisibleStackFrame(const JSC::StackFrame& frame)
{
    return !Zig::isImplementationVisibilityPrivate(frame) && (frame.hasLineAndColumnInfo() || frame.isWasmFrame());
}

static void populateSourceLines(JSC::JSGlobalObject& global, const JSC::StackFrame& frame, Vector<DiagnosticSourceLine>& lines, size_t limit)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto* code = frame.codeBlock();
    if (!limit || !code || !frame.hasBytecodeIndex())
        return;
    auto* provider = code->source().provider();
    if (!provider)
        return;
    StringView source = provider->source();
    auto location = Bun::getAdjustedPositionForBytecode(code, frame.bytecodeIndex());
    if (source.isNull() || location.bytePosition < 0 || static_cast<size_t>(location.bytePosition) > source.length() || location.lineZeroBased < 0)
        return;

    size_t start = location.bytePosition;
    size_t end = start;
    while (start && source[start - 1] != '\n')
        --start;
    while (end < source.length() && source[end] != '\n')
        ++end;
    uint32_t line = location.lineZeroBased;
    while (lines.size() < limit) {
        auto text = copyDiagnosticText(global, source.substring(start, end - start));
        RETURN_IF_EXCEPTION(scope, );
        if (!lines.tryAppend(DiagnosticSourceLine { WTF::move(text), line })) {
            JSC::throwOutOfMemoryError(&global, scope);
            return;
        }
        if (!start || !line)
            return;
        end = start - 1;
        start = end;
        while (start && source[start - 1] != '\n')
            --start;
        --line;
    }
}

static void populateStackTrace(JSC::JSGlobalObject* global, const Vector<JSC::StackFrame>& frames, Vector<DiagnosticFrame>& result, size_t limit, FinalizerSafety safety = FinalizerSafety::NotInFinalizer)
{
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!result.tryReserveCapacity(std::min(frames.size(), limit))) {
        JSC::throwOutOfMemoryError(global, scope);
        return;
    }
    for (const auto& stackFrame : frames) {
        if (result.size() == limit)
            break;
        if (!isVisibleStackFrame(stackFrame))
            continue;
        DiagnosticFrame frame {};
        populateStackFrameMetadata(vm, global, stackFrame, frame, safety);
        RETURN_IF_EXCEPTION(scope, );
        populateStackFramePosition(stackFrame, frame);
        result.append(WTF::move(frame));
    }
}

class V8StackTraceIterator {
public:
    class StackFrame {
    public:
        StringView functionName {};
        StringView sourceURL {};
        WTF::OrdinalNumber lineNumber = WTF::OrdinalNumber::beforeFirst();
        WTF::OrdinalNumber columnNumber = WTF::OrdinalNumber::beforeFirst();

        bool isConstructor = false;
        bool isGlobalCode = false;
        bool isAsync = false;
    };

    WTF::StringView stack;
    unsigned int offset = 0;

    V8StackTraceIterator(WTF::StringView stack_)
        : stack(stack_)
    {
    }

    bool parseFrame(StackFrame& frame)
    {

        if (offset >= stack.length())
            return false;

        auto start = stack.find("\n    at "_s, offset);

        if (start == WTF::notFound) {
            offset = stack.length();
            return false;
        }

        start += 8;
        auto end = stack.find("\n"_s, start);

        if (end == WTF::notFound) {
            offset = stack.length();
            end = offset;
        }

        if (start >= end || start == WTF::notFound) {
            return false;
        }

        StringView line = stack.substring(start, end - start);
        offset = end;

        if (line.startsWith("async "_s)) {
            frame.isAsync = true;
            line = line.substring(6);
        }

        auto openingParentheses = line.find(" ("_s);
        bool hasFunctionName = openingParentheses != WTF::notFound && line.endsWith(')');
        auto lineInner = hasFunctionName
            ? line.substring(openingParentheses + 2, line.length() - openingParentheses - 3)
            : line;

        {
            auto marker1 = 0;
            auto marker2 = lineInner.find(':', marker1);

            if (marker2 == WTF::notFound) {
                frame.sourceURL = lineInner;
                goto done_block;
            }

            auto marker3 = lineInner.find(':', marker2 + 1);
            if (marker3 == WTF::notFound) {
                // /path/to/file.js:
                // /path/to/file.js:1
                // node:child_process
                // C:\Users\chloe\bun\file.js

                marker3 = lineInner.length();

                auto segment1 = StringView_slice(lineInner, marker1, marker2);
                auto segment2 = StringView_slice(lineInner, marker2 + 1, marker3);

                if (auto int1 = WTF::parseIntegerAllowingTrailingJunk<unsigned int>(segment2)) {
                    frame.sourceURL = segment1;
                    frame.lineNumber = WTF::OrdinalNumber::fromOneBasedInt(int1.value());
                } else {
                    frame.sourceURL = StringView_slice(lineInner, marker1, marker3);
                }
                goto done_block;
            }

            // /path/to/file.js:1:
            // /path/to/file.js:1:2
            // node:child_process:1:2
            // C:\Users\chloe\bun\file.js:
            // C:\Users\chloe\bun\file.js:1
            // C:\Users\chloe\bun\file.js:1:2

            while (true) {
                auto newcolon = lineInner.find(':', marker3 + 1);
                if (newcolon == WTF::notFound)
                    break;
                marker2 = marker3;
                marker3 = newcolon;
            }

            auto marker4 = lineInner.length();

            auto segment1 = StringView_slice(lineInner, marker1, marker2);
            auto segment2 = StringView_slice(lineInner, marker2 + 1, marker3);
            auto segment3 = StringView_slice(lineInner, marker3 + 1, marker4);

            if (auto int1 = WTF::parseIntegerAllowingTrailingJunk<unsigned int>(segment2)) {
                if (auto int2 = WTF::parseIntegerAllowingTrailingJunk<unsigned int>(segment3)) {
                    frame.sourceURL = segment1;
                    frame.lineNumber = WTF::OrdinalNumber::fromOneBasedInt(int1.value());
                    frame.columnNumber = WTF::OrdinalNumber::fromOneBasedInt(int2.value());
                } else {
                    frame.sourceURL = segment1;
                    frame.lineNumber = WTF::OrdinalNumber::fromOneBasedInt(int1.value());
                }
            } else {
                if (auto int2 = WTF::parseIntegerAllowingTrailingJunk<unsigned int>(segment3)) {
                    frame.sourceURL = StringView_slice(lineInner, marker1, marker3);
                    frame.lineNumber = WTF::OrdinalNumber::fromOneBasedInt(int2.value());
                } else {
                    frame.sourceURL = StringView_slice(lineInner, marker1, marker4);
                }
            }
        }
    done_block:

        StringView functionName = hasFunctionName ? line.left(openingParentheses) : StringView();

        if (functionName == "global code"_s) {
            functionName = StringView();
            frame.isGlobalCode = true;
        }

        if (functionName.startsWith("new "_s)) {
            frame.isConstructor = true;
            functionName = functionName.substring(4);
        }

        if (functionName == "<anonymous>"_s) {
            functionName = StringView();
        }

        frame.functionName = functionName;

        return true;
    }

    void forEachFrame(const WTF::Function<void(const V8StackTraceIterator::StackFrame&, bool&)> callback)
    {
        bool stop = false;
        while (!stop) {
            StackFrame frame;
            if (!parseFrame(frame))
                break;
            callback(frame, stop);
        }
    }
};

static JSC::JSValue getNonObservable(JSC::VM& vm, JSC::JSGlobalObject* global, JSC::JSObject* obj, const JSC::PropertyName& propertyName)
{
    PropertySlot slot = PropertySlot(obj, PropertySlot::InternalMethodType::VMInquiry, &vm);
    if (obj->getNonIndexPropertySlot(global, propertyName, slot)) {
        if (slot.isAccessor()) {
            return {};
        }

        JSValue value = slot.getValue(global, propertyName);
        if (!value || value.isUndefinedOrNull()) {
            return {};
        }
        return value;
    }
    return {};
}

static Bun::Bindgen::ExceptionRuntimeType bindgenExceptionRuntimeType(JSC::RuntimeType type)
{
    using Type = Bun::Bindgen::ExceptionRuntimeType;
    switch (type) {
    case JSC::TypeNothing:
        return Type::nothing;
    case JSC::TypeFunction:
        return Type::function_value;
    case JSC::TypeUndefined:
        return Type::undefined_value;
    case JSC::TypeNull:
        return Type::null_value;
    case JSC::TypeBoolean:
        return Type::boolean_value;
    case JSC::TypeAnyInt:
        return Type::integer;
    case JSC::TypeNumber:
        return Type::number;
    case JSC::TypeString:
        return Type::string;
    case JSC::TypeObject:
        return Type::object;
    case JSC::TypeSymbol:
        return Type::symbol;
    case JSC::TypeBigInt:
        return Type::bigint;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static void fromErrorInstance(DiagnosticSnapshot& snapshot, JSC::JSGlobalObject* global,
    JSC::ErrorInstance* err, const Vector<JSC::StackFrame>* stackTrace,
    JSC::JSValue val, size_t frameLimit, size_t sourceLineLimit)
{
    auto& except = snapshot.details;
    JSC::JSObject* obj = dynamicDowncast<JSC::JSObject>(val);
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    bool getFromSourceURL = false;
    if (stackTrace != nullptr && stackTrace->size() > 0) {
        populateStackTrace(global, *stackTrace, snapshot.frames, frameLimit);

    } else if (err->stackTrace() != nullptr && err->stackTrace()->size() > 0) {
        populateStackTrace(global, *err->stackTrace(), snapshot.frames, frameLimit, FinalizerSafety::MustNotTriggerGC);

    } else {
        getFromSourceURL = true;
    }
    if (!clearRecoverableDiagnosticException(scope))
        return;
    except.errorCode = diagnosticErrorCode(*err);
    if (except.errorCode == DiagnosticErrorCode::syntax_error) {
        except.message = err->sanitizedMessageString(global);

    } else if (JSC::JSValue message = obj->getIfPropertyExists(global, vm.propertyNames->message)) {
        except.message = message.toWTFString(global);
        if (!clearRecoverableDiagnosticException(scope)) [[unlikely]]
            return;
    } else {

        except.message = err->sanitizedMessageString(global);
    }

    if (!clearRecoverableDiagnosticException(scope)) [[unlikely]] {
        return;
    }

    except.name = err->sanitizedNameString(global);
    if (!clearRecoverableDiagnosticException(scope)) [[unlikely]] {
        return;
    }

    except.runtimeType = bindgenExceptionRuntimeType(err->runtimeTypeForCause());

    const auto& names = builtinNames(vm);
    if (getFromSourceURL && frameLimit) {

        // we don't want to serialize JSC::StackFrame longer than we need to
        // so in this case, we parse the stack trace as a string

        // This one intentionally calls getters.
        JSC::JSValue stackValue = obj->getIfPropertyExists(global, vm.propertyNames->stack);
        if (!clearRecoverableDiagnosticException(scope)) [[unlikely]]
            return;
        if (stackValue) {
            // Prevent infinite recursion if stack property is the error object itself
            if (stackValue == val) {
                return;
            }
            if (stackValue.isString()) {
                WTF::String stack = stackValue.toWTFString(global);
                if (!clearRecoverableDiagnosticException(scope)) [[unlikely]] {
                    return;
                }
                if (!stack.isEmpty()) {

                    V8StackTraceIterator iterator(stack);
                    iterator.forEachFrame([&](const V8StackTraceIterator::StackFrame& frame, bool& stop) {
                        DiagnosticFrame current {};
                        current.functionName = copyDiagnosticText(*global, frame.functionName);
                        if (scope.exception()) {
                            stop = true;
                            return;
                        }
                        current.sourceURL = copyDiagnosticText(*global, frame.sourceURL);
                        if (scope.exception()) {
                            stop = true;
                            return;
                        }
                        current.line = Bun::knownStackIndex(frame.lineNumber.zeroBasedInt());
                        current.column = Bun::knownStackIndex(frame.columnNumber.zeroBasedInt());
                        current.remapped = true;
                        current.isAsync = frame.isAsync;
                        if (frame.isConstructor)
                            current.codeType = Bun::Bindgen::ExceptionStackFrameCode::constructor;
                        else if (frame.isGlobalCode)
                            current.codeType = Bun::Bindgen::ExceptionStackFrameCode::global;
                        if (!snapshot.frames.tryAppend(WTF::move(current))) {
                            throwDiagnosticOutOfMemory(*global);
                            stop = true;
                            return;
                        }
                        stop = snapshot.frames.size() >= frameLimit;
                    });
                    if (!clearRecoverableDiagnosticException(scope))
                        return;

                    if (!snapshot.frames.isEmpty()) {
                        getFromSourceURL = false;
                    }
                }
            }
        }
    }

    if (snapshot.frames.isEmpty() && getFromSourceURL && frameLimit) {
        auto sourceURL = getNonObservable(vm, global, obj, vm.propertyNames->sourceURL);
        if (!clearRecoverableDiagnosticException(scope))
            return;
        if (sourceURL) {
            DiagnosticFrame frame {};
            if (sourceURL.isString()) {
                frame.sourceURL = sourceURL.toWTFString(global);
                if (!clearRecoverableDiagnosticException(scope))
                    return;
                auto column = getNonObservable(vm, global, obj, vm.propertyNames->column);
                if (!clearRecoverableDiagnosticException(scope))
                    return;
                if (column && column.isNumber())
                    frame.column = Bun::knownStackIndex(OrdinalNumber::fromOneBasedInt(column.toInt32(global)).zeroBasedInt());
                auto line = getNonObservable(vm, global, obj, vm.propertyNames->line);
                if (!clearRecoverableDiagnosticException(scope))
                    return;
                if (line && line.isNumber()) {
                    frame.line = Bun::knownStackIndex(OrdinalNumber::fromOneBasedInt(line.toInt32(global)).zeroBasedInt());
                    auto lineText = getNonObservable(vm, global, obj, builtinNames(vm).lineTextPublicName());
                    if (!clearRecoverableDiagnosticException(scope))
                        return;
                    if (lineText && lineText.isString()) {
                        auto text = lineText.toWTFString(global);
                        if (!clearRecoverableDiagnosticException(scope))
                            return;
                        if (sourceLineLimit && frame.line) {
                            if (!snapshot.sourceLines.tryAppend(DiagnosticSourceLine { WTF::move(text), *frame.line })) {
                                throwDiagnosticOutOfMemory(*global);
                                return;
                            }
                        }
                    }
                }
            }
            PropertySlot slot(obj, PropertySlot::InternalMethodType::VMInquiry, &vm);
            frame.remapped = obj->getNonIndexPropertySlot(global, names.originalLinePublicName(), slot);
            if (!clearRecoverableDiagnosticException(scope))
                return;
            if (!snapshot.frames.tryAppend(WTF::move(frame)))
                throwDiagnosticOutOfMemory(*global);
        }
    }
}

static void exceptionFromValue(DiagnosticSnapshot& snapshot, JSC::JSValue value, JSC::JSGlobalObject* global, size_t frameLimit)
{
    auto& except = snapshot.details;
    auto& vm = JSC::getVM(global);
    if (vm.hasPendingTerminationException()) [[unlikely]] {
        return;
    }

    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    // Fallback case for when it's a user-defined ErrorLike-object that doesn't inherit from
    // ErrorInstance
    if (JSC::JSObject* obj = dynamicDowncast<JSC::JSObject>(value)) {
        auto name_value = obj->getIfPropertyExists(global, vm.propertyNames->name);
        if (scope.exception()) [[unlikely]] {
            if (!clearRecoverableDiagnosticException(scope)) return;
        }
        if (name_value) {
            if (name_value.isString()) {
                auto name_str = name_value.toWTFString(global);
                if (!clearRecoverableDiagnosticException(scope))
                    return;
                except.name = name_str;
                if (name_str == "Error"_s) {
                    except.errorCode = DiagnosticErrorCode::generic_error;
                } else if (name_str == "EvalError"_s) {
                    except.errorCode = DiagnosticErrorCode::eval_error;
                } else if (name_str == "RangeError"_s) {
                    except.errorCode = DiagnosticErrorCode::range_error;
                } else if (name_str == "ReferenceError"_s) {
                    except.errorCode = DiagnosticErrorCode::reference_error;
                } else if (name_str == "SyntaxError"_s) {
                    except.errorCode = DiagnosticErrorCode::syntax_error;
                } else if (name_str == "TypeError"_s) {
                    except.errorCode = DiagnosticErrorCode::type_error;
                } else if (name_str == "URIError"_s) {
                    except.errorCode = DiagnosticErrorCode::uri_error;
                } else if (name_str == "AggregateError"_s) {
                    except.errorCode = DiagnosticErrorCode::aggregate_error;
                }
            }
        }

        auto message = obj->getIfPropertyExists(global, vm.propertyNames->message);
        if (scope.exception()) [[unlikely]] {
            if (!clearRecoverableDiagnosticException(scope)) return;
        }
        if (message) {
            if (message.isString()) {
                except.message = message.toWTFString(global);
                if (!clearRecoverableDiagnosticException(scope))
                    return;
            }
        }

        if (snapshot.frames.isEmpty() && frameLimit) {
            DiagnosticFrame frame {};
            bool hasFrame = false;
            auto sourceURL = obj->getIfPropertyExists(global, vm.propertyNames->sourceURL);
            if (scope.exception()) [[unlikely]] {
                if (!clearRecoverableDiagnosticException(scope)) return;
            }
            if (sourceURL) {
                if (sourceURL.isString()) {
                    frame.sourceURL = sourceURL.toWTFString(global);
                    hasFrame = true;
                }
            }

            if (scope.exception()) [[unlikely]] {
                if (!clearRecoverableDiagnosticException(scope)) return;
            }

            auto line = obj->getIfPropertyExists(global, vm.propertyNames->line);
            if (scope.exception()) [[unlikely]] {
                if (!clearRecoverableDiagnosticException(scope)) return;
            }
            if (line) {
                if (line.isNumber()) {
                    frame.line = Bun::knownStackIndex(OrdinalNumber::fromOneBasedInt(line.toInt32(global)).zeroBasedInt());

                    // TODO: don't sourcemap it twice
                    auto originalLine = obj->getIfPropertyExists(global, builtinNames(vm).originalLinePublicName());
                    if (scope.exception()) [[unlikely]] {
                        if (!clearRecoverableDiagnosticException(scope)) return;
                    }
                    if (originalLine) {
                        if (originalLine.isNumber()) {
                            frame.line = Bun::knownStackIndex(OrdinalNumber::fromOneBasedInt(originalLine.toInt32(global)).zeroBasedInt());
                        }
                    }
                    hasFrame = true;
                }
            }
            if (hasFrame && !snapshot.frames.tryAppend(WTF::move(frame))) {
                throwDiagnosticOutOfMemory(*global);
                return;
            }
        }

        if (scope.exception()) [[unlikely]] {
            if (!clearRecoverableDiagnosticException(scope)) return;
        }

        return;
    }

    if (value.isCell()) {
        // This code is mostly here for debugging purposes if this spot is reached.
        JSCell* cell = value.asCell();
        auto type = cell->type();

        switch (type) {
        case JSC::SymbolType: {
            auto* symbol = asSymbol(cell);
            auto& uid = symbol->uid();
            if (uid.isNullSymbol() || uid.isEmpty()) {
                except.message = WTF::emptyString();
            } else {
                except.message = WTF::String(static_cast<WTF::StringImpl*>(&uid));
            }
            return;
        }

        default: {
            break;
        }
        }
    }

    auto str = value.toWTFString(global);
    if (scope.exception()) [[unlikely]] {
        clearRecoverableDiagnosticException(scope);
        return;
    }

    except.message = WTF::move(str);
}

static void populateDiagnostic(JSC::JSGlobalObject* global, JSC::JSValue value, DiagnosticSnapshot& snapshot, size_t frameLimit, size_t sourceLineLimit)
{
    RELEASE_ASSERT(value);
    auto scope = DECLARE_THROW_SCOPE(global->vm());

    if (value.classInfoOrNull() == JSC::Exception::info()) {
        auto* jscException = uncheckedDowncast<JSC::Exception>(value);
        JSValue unwrapped = jscException->value();

        if (JSC::ErrorInstance* error = dynamicDowncast<JSC::ErrorInstance>(unwrapped)) {
            fromErrorInstance(snapshot, global, error, &jscException->stack(), unwrapped, frameLimit, sourceLineLimit);
            return;
        }

        if (jscException->stack().size() > 0) {
            populateStackTrace(global, jscException->stack(), snapshot.frames, frameLimit);
            RETURN_IF_EXCEPTION(scope, );
        }

        exceptionFromValue(snapshot, unwrapped, global, frameLimit);
        return;
    }

    if (JSC::ErrorInstance* error = dynamicDowncast<JSC::ErrorInstance>(value)) {
        fromErrorInstance(snapshot, global, error, nullptr, value, frameLimit, sourceLineLimit);
        return;
    }

    exceptionFromValue(snapshot, value, global, frameLimit);
}

Bun::Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_describeException_Return
Bun::Bindgen::Engine::bunBindgenEngine_JSBundlerPlugin_describeException(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_JSBundlerPlugin_describeException_Arguments& args)
{
    auto& globalObject = context.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(globalObject.vm());
    auto value = args.exception;
    JSC::JSValue errorValue;
    if (value.isCell()) {
        auto* cell = value.asCell();
        if (cell->type() == JSC::ErrorInstanceType) {
            errorValue = value;
        } else if (cell->type() == JSC::CellType && cell->inherits<JSC::Exception>()) {
            errorValue = uncheckedDowncast<JSC::Exception>(cell)->value();
        }
    }

    if (!errorValue) {
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(globalObject.vm());
        auto message = value.toWTFString(&globalObject);
        if (scope.exception()) {
            if (!clearRecoverableDiagnosticException(scope)) return {};
            return {
                .message = "A bundler plugin threw a value that could not be converted to a string"_s,
                .conversionFailed = true,
            };
        }
        return { .message = message, .conversionFailed = false };
    }

    DiagnosticSnapshot snapshot { .details = emptyDiagnosticDetails() };
    populateDiagnostic(&globalObject, errorValue, snapshot, 32, 6);
    RETURN_IF_EXCEPTION(throwScope, {});

    return { .message = WTF::move(snapshot.details.message), .conversionFailed = false };
}

Bun::Bindgen::Engine::BunBindgenEngine_errors_exceptionGetStackTrace_Return
Bun::Bindgen::Engine::bunBindgenEngine_errors_exceptionGetStackTrace(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_errors_exceptionGetStackTrace_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* exception = WTF::downcast<JSC::Exception>(args.exception.asCell());
    Vector<DiagnosticFrame> result;
    populateStackTrace(&context.globalObject, exception->stack(), result, args.limit);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

Bun::Bindgen::Engine::BunBindgenEngine_errors_jsValueDescribeException_Return
Bun::Bindgen::Engine::bunBindgenEngine_errors_jsValueDescribeException(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_errors_jsValueDescribeException_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    DiagnosticSnapshot result { .details = emptyDiagnosticDetails() };
    populateDiagnostic(&context.globalObject, args.value, result, args.frameLimit, args.sourceLineLimit);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

Bun::Bindgen::Engine::BunBindgenEngine_errors_exceptionSourceLines_Return
Bun::Bindgen::Engine::bunBindgenEngine_errors_exceptionSourceLines(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_errors_exceptionSourceLines_Arguments& args)
{
    auto& global = context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    const Vector<JSC::StackFrame>* stack = nullptr;
    if (auto* exception = dynamicDowncast<JSC::Exception>(args.value))
        stack = &exception->stack();
    else if (auto* error = dynamicDowncast<JSC::ErrorInstance>(args.value))
        stack = error->stackTrace();
    if (!stack || stack->isEmpty())
        return std::nullopt;
    Vector<DiagnosticSourceLine> result;
    for (const auto& frame : *stack) {
        if (!isVisibleStackFrame(frame))
            continue;
        populateSourceLines(global, frame, result, args.limit);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        break;
    }
    return result;
}
