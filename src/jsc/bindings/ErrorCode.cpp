
#include "root.h"
#include "SchemaBindings.h"

#include "ZigGlobalObject.h"
#include "DOMException.h"
#include "JavaScriptCore/Error.h"
#include "JavaScriptCore/ErrorType.h"
#include "JavaScriptCore/ObjectConstructor.h"
#include "JavaScriptCore/WriteBarrier.h"
#include "BunClientData.h"
#include "helpers.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/ErrorInstance.h"
#include "JavaScriptCore/JSString.h"
#include "JavaScriptCore/JSType.h"
#include "JavaScriptCore/Symbol.h"
#include "wtf/Assertions.h"
#include "wtf/Vector.h"
#include "wtf/text/ASCIIFastPath.h"
#include "wtf/text/ASCIILiteral.h"
#include "wtf/text/MakeString.h"
#include "wtf/text/WTFString.h"
#include "AbortSignal.h"
#include "JavaScriptCore/ErrorInstanceInlines.h"
#include "JavaScriptCore/JSInternalFieldObjectImplInlines.h"
#include "JSDOMException.h"
#include "JSDOMExceptionHandling.h"
#include <openssl/err.h>
#include "ErrorCode.h"
#include "ErrorStackTrace.h"
#include "KeyObject.h"

namespace WTF {
template<> class StringTypeAdapter<GCOwnedDataScope<StringView>> {
public:
    StringTypeAdapter(GCOwnedDataScope<StringView> string)
        : m_string { string }
    {
    }

    unsigned length() const { return m_string->length(); }
    bool is8Bit() const { return m_string->is8Bit(); }
    template<typename CharacterType> void writeTo(std::span<CharacterType> destination) { m_string->getCharacters(destination); }

private:
    GCOwnedDataScope<StringView> m_string;
};
}

WTF::String Bun::Bindgen::Cpp::bunBindgenCpp_ErrorCode_nodeErrorToString(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_ErrorCode_nodeErrorToString_Arguments& args)
{
    WTF::StringBuilder builder;
    builder.append(args.bindingThis.name);
    builder.append(" ["_s);
    builder.append(args.bindingThis.code);
    builder.append("]: "_s);
    builder.append(args.bindingThis.message);
    return builder.toString();
}

// clang-format on

namespace Bun {

using namespace JSC;
using namespace WTF;

#define BUN_BINDGEN_OBJECT_SURFACE_NodeErrorPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_NodeErrorPrototype

static JSC::JSObject* createErrorPrototype(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::ErrorType type, WTF::ASCIILiteral name, WTF::ASCIILiteral code)
{
    JSC::JSObject* prototype;

    switch (type) {
    case JSC::ErrorType::TypeError:
        prototype = JSC::constructEmptyObject(globalObject, globalObject->m_typeErrorStructure.prototype(globalObject));
        break;
    case JSC::ErrorType::RangeError:
        prototype = JSC::constructEmptyObject(globalObject, globalObject->m_rangeErrorStructure.prototype(globalObject));
        break;
    case JSC::ErrorType::Error:
        prototype = JSC::constructEmptyObject(globalObject, globalObject->errorPrototype());
        break;
    case JSC::ErrorType::URIError:
        prototype = JSC::constructEmptyObject(globalObject, globalObject->m_URIErrorStructure.prototype(globalObject));
        break;
    case JSC::ErrorType::SyntaxError:
        prototype = JSC::constructEmptyObject(globalObject, globalObject->m_syntaxErrorStructure.prototype(globalObject));
        break;
    case JSC::ErrorType::EvalError:
        prototype = JSC::constructEmptyObject(globalObject, globalObject->m_evalErrorStructure.prototype(globalObject));
        break;
    case JSC::ErrorType::ReferenceError:
        prototype = JSC::constructEmptyObject(globalObject, globalObject->m_referenceErrorStructure.prototype(globalObject));
        break;
    case JSC::ErrorType::AggregateError:
        prototype = JSC::constructEmptyObject(globalObject, globalObject->m_aggregateErrorStructure.prototype(globalObject));
        break;
    case JSC::ErrorType::SuppressedError:
        prototype = JSC::constructEmptyObject(globalObject, globalObject->m_suppressedErrorStructure.prototype(globalObject));
        break;
    }

    prototype->putDirect(vm, vm.propertyNames->name, jsString(vm, String(name)), 0);
    prototype->putDirect(vm, WebCore::builtinNames(vm).codePublicName(), jsString(vm, String(code)), 0);
    bunBindgenObjectSurface_NodeErrorPrototype_install(vm, prototype->classInfo(), *prototype);

    return prototype;
}


const ClassInfo ErrorCodeCache::s_info = { "ErrorCodeCache"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(ErrorCodeCache) };

ErrorCodeCache::ErrorCodeCache(VM& vm, Structure* structure)
    : Base(vm, structure)
{
}

template<typename Visitor>
void ErrorCodeCache::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* thisObject = uncheckedDowncast<ErrorCodeCache>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
}

DEFINE_VISIT_CHILDREN_WITH_MODIFIER(JS_EXPORT_PRIVATE, ErrorCodeCache);

Structure* ErrorCodeCache::createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    return Structure::create(vm, globalObject, jsNull(), TypeInfo(InternalFieldTupleType, StructureFlags), info(), 0, 0);
}

ErrorCodeCache* ErrorCodeCache::create(VM& vm, Structure* structure)
{
    ErrorCodeCache* object = new (NotNull, allocateCell<ErrorCodeCache>(vm)) ErrorCodeCache(vm, structure);
    object->finishCreation(vm);
    return object;
}

void ErrorCodeCache::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));

    for (unsigned i = 0; i < NODE_ERROR_COUNT; i++) {
        this->internalField(i).clear();
    }
}

// clang-format on
static Structure* createErrorStructure(JSC::VM& vm, JSGlobalObject* globalObject, JSC::ErrorType type, WTF::ASCIILiteral name, WTF::ASCIILiteral code)
{
    auto* prototype = createErrorPrototype(vm, globalObject, type, name, code);
    return ErrorInstance::createStructure(vm, globalObject, prototype);
}

JSObject* createErrorWithCode(JSGlobalObject* globalObject, ErrorType type, ASCIILiteral name, ASCIILiteral code, const String& message)
{
    auto& vm = getVM(globalObject);
    auto* structure = createErrorStructure(vm, globalObject, type, name, code);
    return ErrorInstance::create(vm, structure, message.isEmpty() ? emptyString() : message, {}, nullptr, RuntimeType::TypeNothing, type, true);
}

Structure* ErrorCodeCache::structureFor(Zig::GlobalObject* globalObject, ErrorCode code)
{
    auto& vm = globalObject->vm();
    auto index = static_cast<unsigned>(code);
    RELEASE_ASSERT(index < NODE_ERROR_COUNT);
    const auto& data = errors[index];
    if (!internalField(index)) {
        auto* structure = createErrorStructure(vm, globalObject, data.type, data.name, data.code);
        internalField(index).set(vm, this, structure);
    }
    return uncheckedDowncast<Structure>(internalField(index).get());
}

static Structure* errorStructure(JSGlobalObject* globalObject, ErrorCode code)
{
    if (auto* zigGlobalObject = dynamicDowncast<Zig::GlobalObject>(globalObject)) {
        auto* cache = uncheckedDowncast<ErrorCodeCache>(zigGlobalObject->nodeErrorCache());
        return cache->structureFor(zigGlobalObject, code);
    }
    auto index = static_cast<unsigned>(code);
    RELEASE_ASSERT(index < NODE_ERROR_COUNT);
    const auto& data = errors[index];
    return createErrorStructure(globalObject->vm(), globalObject, data.type, data.name, data.code);
}

static JSObject* createErrorWithCause(JSGlobalObject* globalObject, ErrorCode code, const String& message, JSValue cause)
{
    auto* structure = errorStructure(globalObject, code);
    // A supplied string creates an own message property even when it is empty.
    return ErrorInstance::create(globalObject->vm(), structure, message.isEmpty() ? emptyString() : message, cause, nullptr, RuntimeType::TypeNothing, errors[static_cast<unsigned>(code)].type, true);
}

JSObject* createError(JSC::JSGlobalObject* globalObject, ErrorCode code, const String& message)
{
    return createErrorWithCause(globalObject, code, message, {});
}

void JSValueToStringSafe(JSC::JSGlobalObject* globalObject, WTF::StringBuilder& builder, JSValue arg, bool quotesLikeInspect = false)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    ASSERT(!arg.isEmpty());
    if (!arg.isCell()) {
        auto text = arg.toWTFStringForConsole(globalObject);
        RETURN_IF_EXCEPTION(scope, );
        builder.append(text);
        return;
    }

    auto cell = arg.asCell();
    switch (cell->type()) {
    case JSC::JSType::StringType: {
        JSString* jsString = dynamicDowncast<JSString>(cell);
        auto str = jsString->view(globalObject);
        RETURN_IF_EXCEPTION(scope, );
        if (quotesLikeInspect) {
            if (str->contains('\'')) {
                builder.append('"');
                if (str->is8Bit()) {
                    const auto span = str->span<Latin1Character>();
                    for (const auto c : span) {
                        if (c == '"') {
                            builder.append("\\\""_s);
                        } else {
                            builder.append(c);
                        }
                    }
                } else {
                    const auto span = str->span<char16_t>();
                    for (const auto c : span) {
                        if (c == '"') {
                            builder.append("\\\""_s);
                        } else {
                            builder.append(c);
                        }
                    }
                }
                builder.append('"');
                return;
            }

            builder.append('\'');
            builder.append(str);
            builder.append('\'');
            return;
        }
        builder.append(str);
        return;
    }
    case JSC::JSType::SymbolType: {
        auto symbol = uncheckedDowncast<Symbol>(cell);
        if (!symbol->uid().isNullSymbol() && !symbol->uid().isEmpty()) {
            auto description = symbol->tryGetDescriptiveString();
            if (!description) {
                JSC::throwOutOfMemoryError(globalObject, scope);
                return;
            }
            builder.append(description.value());
        } else {
            builder.append(globalObject->vm().smallStrings.symbolString());
        }
        return;
    }
    case JSC::JSType::InternalFunctionType:
    case JSC::JSType::JSFunctionType: {
        auto name = Zig::functionName(vm, globalObject, cell->getObject());
        RETURN_IF_EXCEPTION(scope, );

        if (!name.isEmpty()) {
            builder.append("[Function: "_s);
            builder.append(name);
            builder.append(']');
        } else {
            builder.append("[Function (anonymous)]"_s);
        }
        return;
    }

    default: {
        break;
    }
    }

    auto inspected = Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_inspectValueForErrorMessage(globalObject, arg);
    RETURN_IF_EXCEPTION(scope, );
    builder.append(inspected);
}

void determineSpecificType(JSC::VM& vm, JSC::JSGlobalObject* globalObject, WTF::StringBuilder& builder, JSValue value)
{
    auto scope = DECLARE_THROW_SCOPE(vm);

    ASSERT(!value.isEmpty());

    if (value.isNull()) {
        builder.append("null"_s);
        return;
    }
    if (value.isUndefined()) {
        builder.append("undefined"_s);
        return;
    }
    if (value.isNumber()) {
        double d = value.asNumber();
        double infinity = std::numeric_limits<double>::infinity();
        if (d != d) return builder.append("type number (NaN)"_s);
        if (d == infinity) return builder.append("type number (Infinity)"_s);
        if (d == -infinity) return builder.append("type number (-Infinity)"_s);
        builder.append("type number ("_s);
        builder.append(d);
        builder.append(')');
        return;
    }
    if (value.isBoolean()) {
        builder.append(value.asBoolean() ? "type boolean (true)"_s : "type boolean (false)"_s);
        return;
    }
    if (value.isBigInt()) {
        auto str = value.toStringOrNull(globalObject);
        RETURN_IF_EXCEPTION(scope, void());
        auto view = str->view(globalObject);
        RETURN_IF_EXCEPTION(scope, );
        builder.append("type bigint ("_s);
        builder.append(view);
        builder.append("n)"_s);
        return;
    }

    ASSERT(value.isCell());
    auto cell = value.asCell();

    if (cell->isSymbol()) {
        auto symbol = uncheckedDowncast<Symbol>(cell);
        auto result = symbol->tryGetDescriptiveString();
        if (!result) {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return;
        }
        builder.append("type symbol ("_s);
        builder.append(result.value());
        builder.append(")"_s);
        return;
    }
    if (cell->isCallable()) {
        builder.append("function "_s);
        auto name = Zig::functionName(vm, globalObject, cell->getObject());
        RETURN_IF_EXCEPTION(scope, );

        if (!name.isEmpty()) {
            builder.append(name);
        }
        return;
    }
    if (cell->isString()) {
        auto* jsString = uncheckedDowncast<JSString>(cell);
        auto str = jsString->view(globalObject);
        RETURN_IF_EXCEPTION(scope, );

        StringView view = str;

        const bool needsEllipsis = jsString->length() > 28;
        // node checks for the presence of a single quote.
        // - if it does not exist, use single quotes.
        // - if it exists, json stringify (use double quotes).
        // https://github.com/nodejs/node/blob/c3ed292d17c34578fd7806cb42da82bbe0cca103/lib/internal/errors.js#L1030
        const bool needsEscape = str->contains('\'');
        if (needsEllipsis) {
            view = str->substring(0, 25);
        }
        builder.append("type string ("_s);
        if (needsEscape) [[unlikely]] {
            builder.append('"');
            if (view.is8Bit()) {
                const auto span = view.span<Latin1Character>();
                for (const auto c : span) {
                    if (c == '"') {
                        builder.append("\\\""_s);
                    } else {
                        builder.append(c);
                    }
                }
            } else {
                const auto span = view.span<char16_t>();
                for (const auto c : span) {
                    if (c == '"') {
                        builder.append("\\\""_s);
                    } else {
                        builder.append(c);
                    }
                }
            }
        } else {
            builder.append('\'');
            builder.append(view);
        }
        if (needsEllipsis) {
            builder.append("..."_s);
        }
        if (needsEscape) [[unlikely]] {
            builder.append('"');
        } else {
            builder.append('\'');
        }
        builder.append(')');
        return;
    }
    if (cell->isObject()) {
        auto constructor = value.get(globalObject, vm.propertyNames->constructor);
        RETURN_IF_EXCEPTION(scope, void());
        if (constructor.toBoolean(globalObject)) {
            auto name = constructor.get(globalObject, vm.propertyNames->name);
            RETURN_IF_EXCEPTION(scope, void());
            auto str = name.toString(globalObject);
            RETURN_IF_EXCEPTION(scope, void());
            builder.append("an instance of "_s);
            auto view = str->view(globalObject);
            RETURN_IF_EXCEPTION(scope, );
            builder.append(view);
            return;
        }
    }

    JSValueToStringSafe(globalObject, builder, value);
    RETURN_IF_EXCEPTION(scope, );
}

WTF::String Bindgen::Engine::bunBindgenEngine_js_value_inspection_determineSpecificType(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_js_value_inspection_determineSpecificType_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    WTF::StringBuilder builder;
    determineSpecificType(context.globalObject.vm(), &context.globalObject, builder, args.value);
    RETURN_IF_EXCEPTION(scope, {});
    return builder.toString();
}

namespace Message {

void addParameter(WTF::StringBuilder& result, const StringView& arg_name)
{
    if (arg_name.endsWith(" argument"_s)) {
        result.append(arg_name);
    } else {
        result.append("\""_s);
        result.append(arg_name);
        result.append("\" "_s);
        result.append(arg_name.contains('.') ? "property"_s : "argument"_s);
    }
}

WTF::String ERR_INVALID_ARG_TYPE(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, const StringView& arg_name, const StringView& expected_type, JSValue actual_value, bool multiple_types = false)
{
    WTF::StringBuilder result;
    result.append("The "_s);
    addParameter(result, arg_name);
    result.append(multiple_types ? " must be one of type "_s : " must be of type "_s);
    result.append(expected_type);
    result.append(". Received "_s);
    determineSpecificType(JSC::getVM(globalObject), globalObject, result, actual_value);
    RETURN_IF_EXCEPTION(scope, {});
    return result.toString();
}

WTF::String ERR_OUT_OF_RANGE(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, const StringView& arg_name, const StringView& range, JSValue val_input)
{
    WTF::StringBuilder builder;
    builder.append("The value of \""_s);
    builder.append(arg_name);
    builder.append("\" is out of range. It must be "_s);
    builder.append(range);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, val_input);
    RETURN_IF_EXCEPTION(scope, {});

    return builder.toString();
}

}

namespace ERR {

EncodedJSValue INVALID_ARG_TYPE(ThrowScope& scope, JSGlobalObject* globalObject, ASCIILiteral message)
{
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, message));
    scope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_TYPE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& arg_name, const WTF::String& expected_type, JSC::JSValue val_actual_value, bool multiple_types)
{
    auto message = Message::ERR_INVALID_ARG_TYPE(throwScope, globalObject, arg_name, expected_type, val_actual_value, multiple_types);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_TYPE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, JSC::JSValue val_arg_name, const WTF::String& expected_type, JSC::JSValue val_actual_value)
{
    auto* jsString = val_arg_name.toString(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    auto arg_name = jsString->view(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    auto message = Message::ERR_INVALID_ARG_TYPE(throwScope, globalObject, arg_name, expected_type, val_actual_value);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_TYPE_INSTANCE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral arg_name, WTF::ASCIILiteral expected_type, WTF::ASCIILiteral expected_instance_types, JSC::JSValue val_actual_value)
{
    JSC::VM& vm = globalObject->vm();
    WTF::StringBuilder builder;
    builder.append("The \""_s);
    builder.append(arg_name);
    builder.append("\" argument must be of type "_s);
    builder.append(expected_type);
    builder.append(" or an instance of "_s);
    builder.append(expected_instance_types);
    builder.append(". Received "_s);
    determineSpecificType(vm, globalObject, builder, val_actual_value);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_TYPE_INSTANCE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral arg_name, WTF::ASCIILiteral expected_instance_types, JSC::JSValue val_actual_value)
{
    JSC::VM& vm = globalObject->vm();
    WTF::StringBuilder builder;
    builder.append("The \""_s);
    builder.append(arg_name);
    builder.append("\" argument must be an instance of "_s);
    builder.append(expected_instance_types);
    builder.append(". Received "_s);
    determineSpecificType(vm, globalObject, builder, val_actual_value);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, builder.toString()));
    throwScope.release();
    return {};
}

// When you want INVALID_ARG_TYPE to say "The argument must be an instance of X. Received Y." instead of "The argument must be of type X. Received Y."
JSC::EncodedJSValue INVALID_ARG_SAFE_INTEGER(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, const WTF::String& name, JSC::JSValue value)
{
    WTF::StringBuilder message;
    message.append("The \""_s, name, "\" "_s,
        name.contains('.') ? "property"_s : "argument"_s,
        " must be a safe integer. Received "_s);
    determineSpecificType(globalObject->vm(), globalObject, message, value);
    RELEASE_RETURN_IF_EXCEPTION(scope, {});
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, message.toString()));
    scope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_INSTANCE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& arg_name, const WTF::String& expected_type, JSC::JSValue val_actual_value)
{
    auto& vm = JSC::getVM(globalObject);
    ASCIILiteral type = String(arg_name).contains('.') ? "property"_s : "argument"_s;
    WTF::StringBuilder builder;
    builder.append("The \""_s);
    builder.append(arg_name);
    builder.append("\" "_s);
    builder.append(type);
    builder.append(" must be an instance of "_s);
    builder.append(expected_type);
    builder.append(". Received "_s);
    determineSpecificType(vm, globalObject, builder, val_actual_value);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue OUT_OF_RANGE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& arg_name, double lower, double upper, JSC::JSValue actual)
{
    WTF::StringBuilder builder;
    builder.append("The value of \""_s);
    builder.append(arg_name);
    builder.append("\" is out of range. It must be >= "_s);
    builder.append(lower);
    builder.append(" and <= "_s);
    builder.append(upper);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, actual);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_OUT_OF_RANGE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue OUT_OF_RANGE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, JSC::JSValue arg_name_val, double lower, double upper, JSC::JSValue actual)
{
    auto* jsString = arg_name_val.toString(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    auto arg_name = jsString->view(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    WTF::StringBuilder builder;
    builder.append("The value of \""_s);
    builder.append(arg_name);
    builder.append("\" is out of range. It must be >= "_s);
    builder.append(lower);
    builder.append(" and <= "_s);
    builder.append(upper);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, actual);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_OUT_OF_RANGE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue OUT_OF_RANGE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, JSC::JSValue arg_name_val, double bound_num, Bound bound, JSC::JSValue actual)
{
    auto* jsString = arg_name_val.toString(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    auto arg_name = jsString->view(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    WTF::StringBuilder builder;
    builder.append("The value of \""_s);
    builder.append(arg_name);
    builder.append("\" is out of range. It must be "_s);
    builder.append(bound == LOWER ? ">= "_s : "<= "_s);
    builder.append(bound_num);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, actual);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_OUT_OF_RANGE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue OUT_OF_RANGE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, JSC::JSValue arg_name_val, const WTF::String& msg, JSC::JSValue actual)
{
    auto* jsString = arg_name_val.toString(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    auto arg_name = jsString->view(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    WTF::StringBuilder builder;
    builder.append("The value of \""_s);
    builder.append(arg_name);
    builder.append("\" is out of range. It must be "_s);
    builder.append(msg);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, actual);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_OUT_OF_RANGE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue OUT_OF_RANGE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& arg_name, const WTF::String& msg, JSC::JSValue actual)
{
    WTF::StringBuilder builder;
    builder.append("The value of \""_s);
    builder.append(arg_name);
    builder.append("\" is out of range. It must be "_s);
    builder.append(msg);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, actual);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_OUT_OF_RANGE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue OUT_OF_RANGE(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, ASCIILiteral message)
{
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_OUT_OF_RANGE, message));
    scope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_PROPERTY_VALUE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& name, JSC::JSValue value, const WTF::String& expected)
{
    WTF::StringBuilder builder;
    builder.append("The property \""_s, name, "\" is invalid. Expected "_s, expected, ", received "_s);
    determineSpecificType(globalObject->vm(), globalObject, builder, value);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    RELEASE_AND_RETURN(throwScope, Bun::throwError(globalObject, throwScope, ErrorCode::ERR_INVALID_ARG_VALUE, builder.toString()));
}

JSC::EncodedJSValue INVALID_ARG_VALUE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral name, JSC::JSValue value, const WTF::String& reason)
{
    ASCIILiteral type = String(name).contains('.') ? "property"_s : "argument"_s;

    WTF::StringBuilder builder;
    builder.append("The "_s);
    builder.append(type);
    builder.append(" '"_s);
    builder.append(name);
    builder.append("' "_s);
    builder.append(reason);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, value, true);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, builder.toString()));
    throwScope.release();
    return {};
}
template<typename Name>
static JSC::EncodedJSValue invalidArgValueRangeError(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const Name& name, JSC::JSValue value, const WTF::String& reason)
{
    auto& vm = JSC::getVM(globalObject);
    ASCIILiteral type = StringView(name).contains('.') ? "property"_s : "argument"_s;
    WTF::StringBuilder builder;

    builder.append("The "_s);
    builder.append(type);
    builder.append(" '"_s);
    builder.append(name);
    builder.append("' "_s);
    builder.append(reason);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, value, true);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    auto* structure = createErrorStructure(vm, globalObject, ErrorType::RangeError, "RangeError"_s, "ERR_INVALID_ARG_VALUE"_s);
    auto error = JSC::ErrorInstance::create(vm, structure, builder.toString(), jsUndefined(), nullptr, JSC::RuntimeType::TypeNothing, ErrorType::RangeError, true);
    throwScope.throwException(globalObject, error);
    throwScope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_VALUE_RangeError(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral name, JSC::JSValue value, const WTF::String& reason)
{
    return invalidArgValueRangeError(throwScope, globalObject, name, value, reason);
}

JSC::EncodedJSValue INVALID_ARG_VALUE_RangeError(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& name, JSC::JSValue value, const WTF::String& reason)
{
    return invalidArgValueRangeError(throwScope, globalObject, name, value, reason);
}
JSC::EncodedJSValue INVALID_ARG_VALUE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, JSC::JSValue name, JSC::JSValue value, const WTF::String& reason)
{
    WTF::StringBuilder builder;
    builder.append("The argument '"_s);
    auto& vm = JSC::getVM(globalObject);
    determineSpecificType(vm, globalObject, builder, name);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    builder.append("' "_s);
    builder.append(reason);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, value, true);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_VALUE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral name, WTF::ASCIILiteral reason, JSC::JSValue value, const std::span<const ASCIILiteral> oneOf)
{
    WTF::StringBuilder builder;
    builder.append("The "_s);
    if (WTF::find(name.span(), '.') != WTF::notFound) {
        builder.append("property '"_s);
    } else {
        builder.append("argument '"_s);
    }
    builder.append(name);
    builder.append("' "_s);
    builder.append(reason);

    bool first = true;
    for (ASCIILiteral oneOfStr : oneOf) {
        if (!first) {
            builder.append(", "_s);
        }
        first = false;
        builder.append('`');
        builder.append(oneOfStr);
        builder.append('`');
    }

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_VALUE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral name, WTF::ASCIILiteral reason, JSC::JSValue value, const std::span<const int32_t> oneOf)
{
    WTF::StringBuilder builder;
    builder.append("The "_s);
    if (WTF::find(name.span(), '.') != WTF::notFound) {
        builder.append("property '"_s);
    } else {
        builder.append("argument '"_s);
    }
    builder.append(name);
    builder.append("' "_s);
    builder.append(reason);

    bool first = true;
    for (int32_t oneOfStr : oneOf) {
        if (!first) {
            builder.append(", "_s);
        }
        first = false;
        builder.append(oneOfStr);
    }

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue INVALID_ARG_VALUE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& name, JSC::JSValue value, const WTF::String& reason)
{
    WTF::StringBuilder builder;

    builder.append("The "_s);
    if (name.contains('.')) {
        builder.append("property '"_s);
    } else {
        builder.append("argument '"_s);
    }
    builder.append(name);
    builder.append("' "_s);
    builder.append(reason);
    builder.append(". Received "_s);

    JSValueToStringSafe(globalObject, builder, value, true);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue INVALID_URL_SCHEME(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& expectedScheme)
{
    auto message = makeString("The URL must be of scheme "_s, expectedScheme);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_URL_SCHEME, message));
    throwScope.release();
    return {};
}
JSC::EncodedJSValue INVALID_FILE_URL_HOST(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& platform)
{
    auto message = makeString("File URL host must be \"localhost\" or empty on "_s, platform);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_FILE_URL_HOST, message));
    throwScope.release();
    return {};
}
JSC::EncodedJSValue INVALID_FILE_URL_HOST(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const ASCIILiteral platform)
{
    auto message = makeString("File URL host must be \"localhost\" or empty on "_s, platform);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_FILE_URL_HOST, message));
    throwScope.release();
    return {};
}
/// `File URL path {suffix}`
JSC::EncodedJSValue INVALID_FILE_URL_PATH(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const ASCIILiteral suffix)
{
    auto message = makeString("File URL path "_s, suffix);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_FILE_URL_PATH, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue UNKNOWN_ENCODING(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::StringView encoding)
{
    auto message = makeString("Unknown encoding: "_s, encoding);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_UNKNOWN_ENCODING, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue UNKNOWN_ENCODING(JSC::ThrowScope& scope, JSGlobalObject* globalObject, JSValue encodingValue)
{
    WTF::String encodingString = encodingValue.toWTFString(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(scope, {});

    WTF::StringBuilder builder;
    builder.append("Unknown encoding: "_s);
    builder.append(encodingString);
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_UNKNOWN_ENCODING, builder.toString()));
    scope.release();
    return {};
}

JSC::EncodedJSValue INVALID_STATE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& statemsg)
{
    auto message = makeString("Invalid state: "_s, statemsg);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_STATE, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue STRING_TOO_LONG(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    auto message = makeString("Cannot create a string longer than "_s, WTF::String ::MaxLength, " characters"_s);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_STRING_TOO_LONG, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue BUFFER_OUT_OF_BOUNDS(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, ASCIILiteral name)
{
    if (!name.isEmpty()) {
        throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_BUFFER_OUT_OF_BOUNDS, makeString("\""_s, name, "\" is outside of buffer bounds"_s)));
        throwScope.release();
        return {};
    }
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_BUFFER_OUT_OF_BOUNDS, "Attempt to access memory outside buffer bounds"_s));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue UNKNOWN_SIGNAL(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, JSC::JSValue signal, bool triedUppercase)
{
    WTF::StringBuilder builder;
    builder.append("Unknown signal: "_s);
    JSValueToStringSafe(globalObject, builder, signal);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    if (triedUppercase) {
        builder.append(" (signals must use all capital letters)"_s);
    }
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_UNKNOWN_SIGNAL, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue SOCKET_BAD_PORT_NUMBER(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, const WTF::String& name, JSC::JSValue value)
{
    WTF::StringBuilder builder;
    builder.append("The \""_s, name, "\" argument must be a valid IP port number. Got "_s);
    determineSpecificType(scope.vm(), globalObject, builder, value);
    RELEASE_RETURN_IF_EXCEPTION(scope, {});
    builder.append('.');
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_SOCKET_BAD_PORT, builder.toString()));
    scope.release();
    return {};
}

JSC::EncodedJSValue SOCKET_BAD_PORT(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, JSC::JSValue name, JSC::JSValue port, bool allowZero)
{
    ASCIILiteral op = allowZero ? ">="_s : ">"_s;
    WTF::StringBuilder builder;
    JSValueToStringSafe(globalObject, builder, name);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    builder.append(" should be "_s);
    builder.append(op);
    builder.append(" 0 and < 65536. Received "_s);
    JSValueToStringSafe(globalObject, builder, port);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_SOCKET_BAD_PORT, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue UNCAUGHT_EXCEPTION_CAPTURE_ALREADY_SET(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    auto message = "`process.setupUncaughtExceptionCapture()` was called while a capture callback was already active"_s;
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_UNCAUGHT_EXCEPTION_CAPTURE_ALREADY_SET, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue ASSERTION(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, JSC::JSValue msg)
{
    auto msg_string = msg.toWTFString(globalObject);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_ASSERTION, msg_string));
    throwScope.release();
    return {};
}
JSC::EncodedJSValue ASSERTION(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& msg)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_ASSERTION, msg));
    throwScope.release();
    return {};
}
JSC::EncodedJSValue ASSERTION(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, ASCIILiteral msg)
{
    auto message = msg;
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_ASSERTION, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_CURVE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    auto message = "Invalid EC curve name"_s;
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_CURVE, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_KEYTYPE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral message)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_KEYTYPE, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_KEYTYPE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    auto message = "Invalid key type"_s;
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_KEYTYPE, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_UNKNOWN_CIPHER(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::StringView& cipherName)
{
    WTF::StringBuilder builder;
    builder.append("Unknown cipher: "_s);
    builder.append(cipherName);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_UNKNOWN_CIPHER, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_AUTH_TAG(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& message)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_AUTH_TAG, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_IV(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_IV, "Invalid initialization vector"_s));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_UNSUPPORTED_OPERATION(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral message)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_UNSUPPORTED_OPERATION, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_UNSUPPORTED_OPERATION(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_UNSUPPORTED_OPERATION, "Unsupported crypto operation"_s));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_KEYLEN(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_KEYLEN, "Invalid key length"_s));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_STATE(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral message)
{
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_STATE, message));
    scope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_MESSAGELEN(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_MESSAGELEN, "Invalid message length"_s));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue MISSING_ARGS(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral message)
{
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_MISSING_ARGS, message));
    scope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_OPERATION_FAILED(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, ASCIILiteral message)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_KEYPAIR(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    auto message = "Invalid key pair"_s;
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_KEYPAIR, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_ECDH_INVALID_PUBLIC_KEY(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    auto message = "Public key is not valid for specified curve"_s;
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_ECDH_INVALID_PUBLIC_KEY, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_JWK_UNSUPPORTED_CURVE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::String& curve)
{
    WTF::StringBuilder builder;
    builder.append("Unsupported JWK EC curve: "_s);
    builder.append(curve);
    builder.append('.');
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_JWK_UNSUPPORTED_CURVE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_JWK_UNSUPPORTED_CURVE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, ASCIILiteral message, const char* curveName)
{
    WTF::StringBuilder builder;
    builder.append(message);
    if (curveName) {
        builder.append(std::span<const char> { curveName, strlen(curveName) });
    }
    builder.append('.');
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_JWK_UNSUPPORTED_CURVE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_JWK_UNSUPPORTED_KEY_TYPE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_JWK_UNSUPPORTED_KEY_TYPE, "Unsupported JWK Key Type."_s));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_JWK(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_JWK, "Invalid JWK data"_s));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_JWK(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, ASCIILiteral message)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_JWK, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_SIGN_KEY_REQUIRED(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    auto message = "No key provided to sign"_s;
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_SIGN_KEY_REQUIRED, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_KEY_OBJECT_TYPE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, JSValue received, WTF::ASCIILiteral expected)
{
    WTF::StringBuilder builder;
    builder.append("Invalid key object type "_s);
    JSValueToStringSafe(globalObject, builder, received);
    RELEASE_RETURN_IF_EXCEPTION(throwScope, {});

    builder.append(". Expected "_s);
    builder.append(expected);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_KEY_OBJECT_TYPE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_KEY_OBJECT_TYPE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, CryptoKeyType receivedType, ASCIILiteral expected)
{
    WTF::StringBuilder builder;
    builder.append("Invalid key object type "_s);
    switch (receivedType) {
    case CryptoKeyType::Private:
        builder.append("private"_s);
        break;
    case CryptoKeyType::Public:
        builder.append("public"_s);
        break;
    case CryptoKeyType::Secret:
        builder.append("secret"_s);
        break;
    }
    builder.append(", expected "_s);
    builder.append(expected);
    builder.append('.');
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_KEY_OBJECT_TYPE, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INCOMPATIBLE_KEY_OPTIONS(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::StringView& receivedKeyEncoding, const WTF::String& expectedOperation)
{
    WTF::StringBuilder builder;
    builder.append("The selected key encoding "_s);
    builder.append(receivedKeyEncoding);
    builder.append(' ');
    builder.append(expectedOperation);
    builder.append('.');
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INCOMPATIBLE_KEY_OPTIONS, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_DIGEST(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, const WTF::StringView& digest)
{
    WTF::StringBuilder builder;
    builder.append("Invalid digest: "_s);
    builder.append(digest);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_DIGEST, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_INVALID_DIGEST(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, ASCIILiteral message, const WTF::StringView& digest)
{
    WTF::StringBuilder builder;
    builder.append(message);
    builder.append(digest);
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_DIGEST, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_HASH_FINALIZED(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_HASH_FINALIZED, "Digest already called"_s));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_HASH_UPDATE_FAILED(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_HASH_UPDATE_FAILED, "Hash update failed"_s));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_TIMING_SAFE_EQUAL_LENGTH(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject)
{
    auto message = "Input buffers must have the same byte length"_s;
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH, message));
    scope.release();
    return {};
}

JSC::EncodedJSValue CRYPTO_UNKNOWN_DH_GROUP(JSC::ThrowScope& scope, JSGlobalObject* globalObject)
{
    auto message = "Unknown DH group"_s;
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_UNKNOWN_DH_GROUP, message));
    scope.release();
    return {};
}

JSC::EncodedJSValue OSSL_EVP_INVALID_DIGEST(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject)
{
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_OSSL_EVP_INVALID_DIGEST, "Invalid digest used"_s));
    scope.release();
    return {};
}

JSC::EncodedJSValue MISSING_PASSPHRASE(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral message)
{
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_MISSING_PASSPHRASE, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue KEY_GENERATION_JOB_FAILED(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject)
{
    auto message = "Key generation job failed"_s;
    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_KEY_GENERATION_JOB_FAILED, message));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue INCOMPATIBLE_OPTION_PAIR(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::StringView opt1, WTF::StringView opt2)
{
    WTF::StringBuilder builder;
    builder.append("Option \""_s);
    builder.append(opt1);
    builder.append("\" cannot be used in combination with option \""_s);
    builder.append(opt2);
    builder.append("\""_s);

    throwScope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INCOMPATIBLE_OPTION_PAIR, builder.toString()));
    throwScope.release();
    return {};
}

JSC::EncodedJSValue MISSING_OPTION(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, ASCIILiteral message)
{
    WTF::StringBuilder builder;
    builder.append(message);
    builder.append(" is required"_s);
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_MISSING_OPTION, builder.toString()));
    scope.release();
    return {};
}

JSC::EncodedJSValue INVALID_MIME_SYNTAX(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, const String& part, const String& input, int position)
{
    WTF::StringBuilder builder;
    builder.append("The MIME syntax for a "_s);
    builder.append(part);
    builder.append(" in "_s);
    builder.append(input);

    builder.append(" is invalid"_s);
    if (position != -1) {
        builder.append(" at "_s);
        builder.append(String::number(position));
    }

    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_MIME_SYNTAX, builder.toString()));
    scope.release();
    return {};
}

EncodedJSValue CLOSED_MESSAGE_PORT(ThrowScope& scope, JSGlobalObject* globalObject)
{
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CLOSED_MESSAGE_PORT, "Cannot send data on closed MessagePort"_s));
    scope.release();
    return {};
}

JSC::EncodedJSValue INVALID_THIS(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, ASCIILiteral expectedType)
{
    WTF::StringBuilder builder;
    builder.append("Value of \"this\" must be of type "_s);
    builder.append(expectedType);
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_INVALID_THIS, builder.toString()));
    scope.release();
    return {};
}

JSC::EncodedJSValue DLOPEN_DISABLED(JSC::ThrowScope& scope, JSC::JSGlobalObject* globalObject, ASCIILiteral message)
{
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_DLOPEN_DISABLED, message));
    scope.release();
    return {};
}

} // namespace ERR

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ErrorCode_invalidArgTypeError(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ErrorCode_invalidArgTypeError_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto message = Message::ERR_INVALID_ARG_TYPE(scope, globalObject, args.name, args.expected, args.actual);
    RETURN_IF_EXCEPTION(scope, {});
    return createError(globalObject, ErrorCode::ERR_INVALID_ARG_TYPE, message);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ErrorCode_invalidArgValueError(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ErrorCode_invalidArgValueError_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    WTF::StringBuilder builder;
    builder.append("The "_s);
    builder.append(args.name.contains('.') ? "property"_s : "argument"_s);
    builder.append(" '"_s);
    builder.append(args.name);
    builder.append("' "_s);
    builder.append(args.reason);
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, args.actual, true);
    RETURN_IF_EXCEPTION(scope, {});
    return createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, builder.toString());
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ErrorCode_invalidOneOfError(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ErrorCode_invalidOneOfError_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    WTF::StringBuilder builder;
    builder.append("The argument '"_s, args.name, "' must be one of: "_s);
    bool first = true;
    for (auto value : args.values) {
        if (!first)
            builder.append(", "_s);
        first = false;
        JSValueToStringSafe(globalObject, builder, value, true);
        RETURN_IF_EXCEPTION(scope, {});
    }
    builder.append(". Received "_s);
    JSValueToStringSafe(globalObject, builder, args.actual, true);
    RETURN_IF_EXCEPTION(scope, {});
    return createError(globalObject, ErrorCode::ERR_INVALID_ARG_VALUE, builder.toString());
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ErrorCode_outOfRangeError(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ErrorCode_outOfRangeError_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto message = Message::ERR_OUT_OF_RANGE(scope, globalObject, args.name, args.range, args.actual);
    RETURN_IF_EXCEPTION(scope, {});
    return createError(globalObject, ErrorCode::ERR_OUT_OF_RANGE, message);
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ErrorCode_describeValueType(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ErrorCode_describeValueType_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    WTF::StringBuilder builder;
    determineSpecificType(context.globalObject.vm(), &context.globalObject, builder, args.value);
    RETURN_IF_EXCEPTION(scope, {});
    return builder.toString();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ErrorCode_createFromMessage(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ErrorCode_createFromMessage_Arguments& args)
{
    return createError(&context.globalObject, args.code, args.message);
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_ErrorCode_create(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_ErrorCode_create_Arguments& args)
{
    return createError(&context.globalObject, args.code, args.message);
}

void Bindgen::Engine::bunBindgenEngine_ErrorCode_throw(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_ErrorCode_throw_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto error = createError(&context.globalObject, args.code, args.message);
    RETURN_IF_EXCEPTION(scope, );
    scope.throwException(&context.globalObject, error);
}

void throwBoringSSLError(JSGlobalObject* globalObject, JSC::ThrowScope& scope, int errorCode)
{
    char buf[256] = { 0 };
    ERR_error_string_n(static_cast<uint32_t>(errorCode), buf, sizeof(buf));
    auto message = String::fromUTF8(buf);
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_INVALID_STATE, message));
}

void throwCryptoOperationFailed(JSGlobalObject* globalObject, JSC::ThrowScope& scope)
{
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "Crypto operation failed"_s));
}

} // namespace Bun

static JSC::JSValue createNodeAbortError(JSC::JSGlobalObject* globalObject, JSC::JSValue cause)
{
    return Bun::createErrorWithCause(globalObject, Bun::ErrorCode::ABORT_ERR, "The operation was aborted."_s, cause.isUndefined() ? JSC::JSValue() : cause);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_errors_wrapAbortError(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_errors_wrapAbortError_Arguments& args)
{
    return createNodeAbortError(&context.globalObject, args.cause);
}

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_abortSignalNodeAbortError(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_abort_signals_abortSignalNodeAbortError_Arguments& args)
{
    if (!args.signal->aborted())
        return std::nullopt;
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto reason = args.signal->jsReason(context.globalObject);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    RELEASE_AND_RETURN(scope, createNodeAbortError(&context.globalObject, reason));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_ErrorCode_makeAbortError(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_ErrorCode_makeAbortError_Arguments& args)
{
    auto cause = args.options ? args.options->cause.value_or(JSC::JSValue()) : JSC::JSValue();
    return Bun::createErrorWithCause(&context.globalObject, Bun::ErrorCode::ABORT_ERR, args.message, cause);
}

JSC::JSValue WebCore::toJS(JSC::JSGlobalObject* globalObject, CommonAbortReason abortReason)
{
    switch (abortReason) {
    case CommonAbortReason::Timeout: {
        return createDOMException(globalObject, ExceptionCode::TimeoutError, "The operation timed out."_s);
    }
    case CommonAbortReason::UserAbort: {
        return createDOMException(globalObject, ExceptionCode::AbortError, "The operation was aborted."_s);
    }
    case CommonAbortReason::ConnectionClosed: {
        return createDOMException(globalObject, ExceptionCode::AbortError, "The connection was closed."_s);
    }
    default: {
        break;
    }
    }

    RELEASE_ASSERT_NOT_REACHED();
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_abort_signals_commonAbortReasonToJS(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_abort_signals_commonAbortReasonToJS_Arguments& args)
{
    switch (args.value) {
    case Bun::Bindgen::CommonAbortReason::Timeout:
        return WebCore::toJS(&context.globalObject, WebCore::CommonAbortReason::Timeout);
    case Bun::Bindgen::CommonAbortReason::UserAbort:
        return WebCore::toJS(&context.globalObject, WebCore::CommonAbortReason::UserAbort);
    case Bun::Bindgen::CommonAbortReason::ConnectionClosed:
        return WebCore::toJS(&context.globalObject, WebCore::CommonAbortReason::ConnectionClosed);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

JSC::JSObject* Bun::createInvalidThisError(JSC::JSGlobalObject* globalObject, const String& message)
{
    return Bun::createError(globalObject, Bun::ErrorCode::ERR_INVALID_THIS, message);
}

JSC::JSObject* Bun::createInvalidThisError(JSC::JSGlobalObject* globalObject, JSC::JSValue thisValue, const ASCIILiteral typeName)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (thisValue.isEmpty() || thisValue.isUndefined()) {
        RELEASE_AND_RETURN(scope, Bun::createError(globalObject, Bun::ErrorCode::ERR_INVALID_THIS, makeString("Expected this to be instanceof "_s, typeName)));
    }

    WTF::StringBuilder builder;
    builder.append("Expected this to be instanceof "_s);
    builder.append(typeName);
    builder.append(", but received "_s);
    determineSpecificType(JSC::getVM(globalObject), globalObject, builder, thisValue);
    RETURN_IF_EXCEPTION(scope, nullptr);
    RELEASE_AND_RETURN(scope, Bun::createError(globalObject, Bun::ErrorCode::ERR_INVALID_THIS, builder.toString()));
}

JSC::EncodedJSValue Bun::throwError(JSC::JSGlobalObject* globalObject, JSC::ThrowScope& scope, Bun::ErrorCode code, const WTF::String& message)
{
    scope.throwException(globalObject, createError(globalObject, code, message));
    return {};
}
