#include "root.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"

#include "JSWrappingFunction.h"
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <wtf/text/ExternalStringImpl.h>

#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/HeapAnalyzer.h>

#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/SubspaceInlines.h>

namespace Zig {
using namespace JSC;

const ClassInfo JSWrappingFunction::s_info = { "Function"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSWrappingFunction) };

JS_EXPORT_PRIVATE JSWrappingFunction* JSWrappingFunction::create(
    VM& vm,
    Zig::GlobalObject* globalObject,
    const WTF::String& symbolName,
    Zig::NativeFunctionPtr functionPointer,
    JSC::JSValue wrappedFnValue)
{
    JSC::JSObject* wrappedFn = wrappedFnValue.getObject();
    ASSERT(wrappedFn != nullptr);

    NativeExecutable* executable = vm.getHostFunction(functionPointer, ImplementationVisibility::Public, callHostFunctionAsConstructor, 0, symbolName);

    // Structure* structure = globalObject->FFIFunctionStructure();
    Structure* structure = JSWrappingFunction::createStructure(vm, globalObject, globalObject->objectPrototype());
    JSWrappingFunction* function = new (NotNull, allocateCell<JSWrappingFunction>(vm)) JSWrappingFunction(vm, executable, globalObject, structure, wrappedFn);
    ASSERT(function->structure()->globalObject());
    function->finishCreation(vm);

    return function;
}

template<typename Visitor>
void JSWrappingFunction::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSWrappingFunction* thisObject = uncheckedDowncast<JSWrappingFunction>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);

    visitor.append(thisObject->m_wrappedFn);
}

DEFINE_VISIT_CHILDREN(JSWrappingFunction);

}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_Expect_createArgumentArray(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_Expect_createArgumentArray_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    RELEASE_AND_RETURN(scope, JSC::constructArray(&context.globalObject, static_cast<JSC::ArrayAllocationProfile*>(nullptr), args.values.data(), args.values.size()));
}

void Bun::Bindgen::Engine::bunBindgenEngine_Expect_installCustomMatcher(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_Expect_installCustomMatcher_Arguments& args)
{
    auto* realmGlobalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    auto* defaultGlobal = defaultGlobalObject(&context.globalObject);
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* wrapper = Zig::JSWrappingFunction::create(
        vm,
        defaultGlobal,
        args.symbolName,
        ::bun_bindgen_host_Expect_applyCustomMatcher,
        args.wrappedFunction);
    auto property = JSC::PropertyName(JSC::Identifier::fromString(vm, args.symbolName));

    realmGlobalObject->BunBindgen_Expect_ExpectPrototype()->putDirectMayBeIndex(&context.globalObject, property, wrapper);
    RETURN_IF_EXCEPTION(scope, );
    defaultGlobal->BunBindgen_Expect_ExpectConstructor()->putDirectMayBeIndex(&context.globalObject, property, wrapper);
    RETURN_IF_EXCEPTION(scope, );
    realmGlobalObject->BunBindgen_Expect_ExpectStaticPrototype()->putDirectMayBeIndex(&context.globalObject, property, wrapper);
    RETURN_IF_EXCEPTION(scope, );
    scope.release();
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_Expect_wrappingFunctionWrapped(
    Bun::Bindgen::EngineCallContext&,
    const Bun::Bindgen::Engine::BunBindgenEngine_Expect_wrappingFunctionWrapped_Arguments& args)
{
    auto* function = dynamicDowncast<Zig::JSWrappingFunction>(args.function);
    RELEASE_ASSERT(function);
    return function->wrappedFunction();
}
