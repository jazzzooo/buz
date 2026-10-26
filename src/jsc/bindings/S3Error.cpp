
#include "root.h"

#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/ErrorInstanceInlines.h>
#include <wtf/Compiler.h>
#include "SchemaBindings.h"
#include "S3Error.h"

namespace Bun {

Structure* createS3ErrorStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    return JSC::ErrorInstance::createStructure(vm, globalObject, JSC::constructEmptyObject(globalObject, globalObject->errorPrototype()));
}

template<typename Data>
static JSC::JSValue createS3Error(JSC::JSGlobalObject* globalObject, const Data& data)
{
    auto& vm = JSC::getVM(globalObject);
    auto& names = WebCore::builtinNames(vm);

    auto prototype = defaultGlobalObject(globalObject)->m_S3ErrorStructure.getInitializedOnMainThread(globalObject);
    JSC::JSObject* result = JSC::ErrorInstance::create(vm, prototype, data.message, {});
    result->putDirect(vm, vm.propertyNames->name, defaultGlobalObject(globalObject)->commonStrings().s3ErrorString(globalObject), JSC::PropertyAttribute::DontEnum | 0);
    if (data.code) {
        result->putDirect(vm, names.codePublicName(), JSC::jsString(vm, *data.code),
            JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::DontEnum | 0);
    }

    if (data.path) {
        result->putDirect(vm, names.pathPublicName(), JSC::jsString(vm, *data.path),
            JSC::PropertyAttribute::DontDelete | 0);
    }

    return result;
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_errors_s3ErrorToErrorInstance(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_errors_s3ErrorToErrorInstance_Arguments& args)
{
    return createS3Error(&context.globalObject, args.data);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_S3Errors_createS3Error(
    Bindgen::CppCallContext& context,
    const BunBindgenCpp_S3Errors_createS3Error_Arguments& args)
{
    return createS3Error(&context.globalObject, args.data);
}
}
