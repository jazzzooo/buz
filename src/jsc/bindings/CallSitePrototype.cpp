/**
 * This source code is licensed under the terms found in the LICENSE file in
 * node-jsc's root directory.
 */

#include "config.h"
#include "CallSitePrototype.h"
#include "CallSite.h"
#include "SchemaBindings.h"
#include "helpers.h"

#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/CodeBlock.h>
#include <JavaScriptCore/Operations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSBoundFunction.h>
#include <wtf/text/MakeString.h>
using namespace JSC;

namespace Zig {

#define BUN_BINDGEN_OBJECT_SURFACE_CallSitePrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_CallSitePrototype

const JSC::ClassInfo CallSitePrototype::s_info = { "CallSite"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(CallSitePrototype) };

void CallSitePrototype::finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));

    bunBindgenObjectSurface_CallSitePrototype_install(vm, CallSite::info(), *this);
}

}

namespace Bun::Bindgen::Cpp {

static Zig::CallSite* callSiteObject(JSC::JSValue value)
{
    auto* callSite = dynamicDowncast<Zig::CallSite>(value);
    RELEASE_ASSERT(callSite);
    return callSite;
}

JSC::JSValue bunBindgenCpp_CallSite_getThis(CppCallContext& context, const BunBindgenCpp_CallSite_getThis_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite ? callSite->thisValue() : JSC::jsUndefined();
}

WTF::String bunBindgenCpp_CallSite_getTypeName(CppCallContext& context, const BunBindgenCpp_CallSite_getTypeName_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    if (!callSite)
        return {};
    return JSC::jsTypeStringForValue(&context.globalObject, callSite->thisValue())->value(&context.globalObject);
}

JSC::JSValue bunBindgenCpp_CallSite_getFunction(CppCallContext& context, const BunBindgenCpp_CallSite_getFunction_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite ? callSite->function() : JSC::jsUndefined();
}

WTF::String bunBindgenCpp_CallSite_getFunctionName(CppCallContext& context, const BunBindgenCpp_CallSite_getFunctionName_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite ? callSite->functionName().toWTFString(&context.globalObject) : WTF::String {};
}

WTF::String bunBindgenCpp_CallSite_getMethodName(CppCallContext& context, const BunBindgenCpp_CallSite_getMethodName_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite ? callSite->functionName().toWTFString(&context.globalObject) : WTF::String {};
}

WTF::String bunBindgenCpp_CallSite_getFileName(CppCallContext& context, const BunBindgenCpp_CallSite_getFileName_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite ? callSite->sourceURL().toWTFString(&context.globalObject) : WTF::String {};
}

int32_t bunBindgenCpp_CallSite_getLineNumber(CppCallContext& context, const BunBindgenCpp_CallSite_getLineNumber_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite ? std::max(callSite->lineNumber().oneBasedInt(), 1) : 0;
}

int32_t bunBindgenCpp_CallSite_getColumnNumber(CppCallContext& context, const BunBindgenCpp_CallSite_getColumnNumber_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite ? std::max(callSite->columnNumber().zeroBasedInt(), 0) : 0;
}

void bunBindgenCpp_CallSite_getEvalOrigin(CppCallContext& context, const BunBindgenCpp_CallSite_getEvalOrigin_Arguments& args)
{
    (void)args.bindingThis;
}

WTF::String bunBindgenCpp_CallSite_getScriptNameOrSourceURL(CppCallContext& context, const BunBindgenCpp_CallSite_getScriptNameOrSourceURL_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite ? callSite->sourceURL().toWTFString(&context.globalObject) : WTF::String {};
}

bool bunBindgenCpp_CallSite_isToplevel(CppCallContext& context, const BunBindgenCpp_CallSite_isToplevel_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    if (!callSite)
        return false;

    if (JSC::JSValue functionValue = callSite->function()) {
        if (JSC::JSObject* functionObject = functionValue.getObject()) {
            if (JSC::JSFunction* function = dynamicDowncast<JSC::JSFunction>(functionObject)) {
                if (function->inherits<JSC::JSBoundFunction>())
                    return false;
                if (function->isHostFunction())
                    return true;
                if (auto* executable = function->jsExecutable())
                    return executable->isProgramExecutable() || executable->isModuleProgramExecutable();
            } else if (dynamicDowncast<JSC::InternalFunction>(functionValue)) {
                return true;
            }
        }
    }

    JSC::JSValue thisValue = callSite->thisValue();
    if (thisValue.isUndefinedOrNull())
        return true;
    JSC::JSObject* thisObject = thisValue.getObject();
    return thisObject && thisObject->isGlobalObject();
}

bool bunBindgenCpp_CallSite_isEval(CppCallContext& context, const BunBindgenCpp_CallSite_isEval_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite && callSite->isEval();
}

bool bunBindgenCpp_CallSite_isNative(CppCallContext& context, const BunBindgenCpp_CallSite_isNative_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite && callSite->isNative();
}

bool bunBindgenCpp_CallSite_isConstructor(CppCallContext& context, const BunBindgenCpp_CallSite_isConstructor_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite && callSite->isConstructor();
}

bool bunBindgenCpp_CallSite_isAsync(CppCallContext& context, const BunBindgenCpp_CallSite_isAsync_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return callSite && callSite->isAsync();
}

bool bunBindgenCpp_CallSite_isPromiseAll(CppCallContext& context, const BunBindgenCpp_CallSite_isPromiseAll_Arguments& args)
{
    (void)args.bindingThis;
    return false;
}

std::optional<int32_t> bunBindgenCpp_CallSite_getPromiseIndex(CppCallContext& context, const BunBindgenCpp_CallSite_getPromiseIndex_Arguments& args)
{
    (void)args.bindingThis;
    return std::nullopt;
}

WTF::String bunBindgenCpp_CallSite_toString(CppCallContext& context, const BunBindgenCpp_CallSite_toString_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    if (!callSite)
        return {};
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    WTF::StringBuilder builder(OverflowPolicy::RecordOverflow);
    callSite->formatAsString(vm, globalObject, builder);
    RETURN_IF_EXCEPTION(scope, {});
    if (builder.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto result = tryMakeString(StringView(builder));
    if (result.isNull())
        throwOutOfMemoryError(globalObject, scope);
    return result;
}

CallSiteJSONDictionaryResult bunBindgenCpp_CallSite_toJSON(CppCallContext& context, const BunBindgenCpp_CallSite_toJSON_Arguments& args)
{
    auto* callSite = callSiteObject(args.bindingThis);
    return {
        .sourceURL = callSite->sourceURL().toWTFString(&context.globalObject),
        .lineNumber = callSite->lineNumber().oneBasedInt(),
        .columnNumber = callSite->columnNumber().zeroBasedInt(),
        .functionName = callSite->functionName().toWTFString(&context.globalObject),
    };
}

}
