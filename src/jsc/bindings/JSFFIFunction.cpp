/*
 * Copyright (C) 2015-2021 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "root.h"
#include "SchemaBindings.h"
#include "JSFFIFunction.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/VM.h>

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_js_functions_bindingFunctionCreate(
    EngineCallContext& context,
    const BunBindgenEngine_js_functions_bindingFunctionCreate_Arguments& args)
{
    return JSC::JSFunction::create(context.globalObject.vm(), &context.globalObject, args.argumentCount, args.symbolName, args.function, JSC::ImplementationVisibility::Public);
}

void Bun::Bindgen::Engine::bunBindgenEngine_FFI_ffiLibraryInstallSymbols(
    EngineCallContext& context,
    const BunBindgenEngine_FFI_ffiLibraryInstallSymbols_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto library = context.classValue(args.library);
    auto* symbols = JSC::constructEmptyObject(
        globalObject,
        globalObject->objectPrototype(),
        std::min(args.symbols.size(), static_cast<size_t>(JSC::JSFinalObject::maxInlineCapacity)));
    RETURN_IF_EXCEPTION(scope, void());
    for (const auto& symbol : args.symbols) {
        auto function = Bun::Bindgen::ZigExports::bunBindgenZig_FFI_adoptForeignFunction(globalObject, library, symbol.index);
        RETURN_IF_EXCEPTION(scope, void());
        symbols->putDirect(vm, JSC::Identifier::fromString(vm, symbol.name), function);
        RETURN_IF_EXCEPTION(scope, void());
    }
    bun_bindgen_class_FFI_FFI_slot_symbolsValue_set_value(globalObject, library, symbols);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_js_functions_bindingFunctionCreateWithData(
    EngineCallContext& context,
    const BunBindgenEngine_js_functions_bindingFunctionCreateWithData_Arguments& args)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto* function = Zig::JSFFIFunction::create(globalObject->vm(), globalObject, args.argumentCount, args.symbolName, args.function);
    function->dataPtr = args.data;
    return function;
}

void Bun::Bindgen::Engine::bunBindgenEngine_js_functions_bindingFunctionClearData(
    EngineCallContext&,
    const BunBindgenEngine_js_functions_bindingFunctionClearData_Arguments& args)
{
    auto* function = dynamicDowncast<Zig::JSFFIFunction>(args.function);
    RELEASE_ASSERT(function);
    function->dataPtr = nullptr;
}

namespace Zig {
using namespace JSC;

const ClassInfo JSFFIFunction::s_info = { "Function"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSFFIFunction) };

JSFFIFunction::JSFFIFunction(VM& vm, NativeExecutable* executable, JSGlobalObject* globalObject, Structure* structure)
    : Base(vm, executable, globalObject, structure)
{
}

JSFFIFunction* JSFFIFunction::create(VM& vm, Zig::GlobalObject* globalObject, unsigned length, const String& name, NativeFunction nativeFunction)
{
    NativeExecutable* executable = vm.getHostFunction(nativeFunction, ImplementationVisibility::Public, NoIntrinsic, callHostFunctionAsConstructor, nullptr, length, name);
    Structure* structure = globalObject->FFIFunctionStructure();
    JSFFIFunction* function = new (NotNull, allocateCell<JSFFIFunction>(vm)) JSFFIFunction(vm, executable, globalObject, structure);
    function->finishCreation(vm);
    return function;
}

} // namespace Zig
