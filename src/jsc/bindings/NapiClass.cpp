#include "root.h"
#include "napi.h"
#include <wtf/TZoneMallocInlines.h>

namespace Zig {

template<typename Visitor>
void NapiClass::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    NapiClass* thisObject = uncheckedDowncast<NapiClass>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
}

DEFINE_VISIT_CHILDREN(NapiClass);

template<bool ConstructCall>
JSC_HOST_CALL_ATTRIBUTES JSC::EncodedJSValue NapiClass_ConstructorFunction(JSC::JSGlobalObject* globalObject, JSC::CallFrame* callFrame)
{
    JSC::VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSObject* constructorTarget = asObject(callFrame->jsCallee());
    NapiClass* napi = dynamicDowncast<NapiClass>(constructorTarget);
    while (!napi && constructorTarget) {
        constructorTarget = constructorTarget->getPrototypeDirect().getObject();
        napi = dynamicDowncast<NapiClass>(constructorTarget);
    }

    if (!napi) [[unlikely]] {
        JSC::throwVMError(globalObject, scope, JSC::createTypeError(globalObject, "NapiClass constructor called on an object that is not a NapiClass"_s));
        return {};
    }

    JSValue newTarget;

    if constexpr (ConstructCall) {
        newTarget = callFrame->newTarget();
        JSObject* thisValue;
        if (newTarget != napi) {
            JSGlobalObject* functionGlobalObject = getFunctionRealm(globalObject, asObject(newTarget));
            RETURN_IF_EXCEPTION(scope, {});
            Structure* baseStructure = functionGlobalObject->objectStructureForObjectConstructor();
            Structure* objectStructure = InternalFunction::createSubclassStructure(globalObject, asObject(newTarget), baseStructure);
            RETURN_IF_EXCEPTION(scope, {});
            thisValue = constructEmptyObject(vm, objectStructure);
        } else {
            Structure* baseStructure = napi->env()->globalObject()->NapiPrototypeStructure();
            Structure* objectStructure = InternalFunction::createSubclassStructure(globalObject, asObject(newTarget), baseStructure);
            RETURN_IF_EXCEPTION(scope, {});
            thisValue = NapiPrototype::create(vm, objectStructure);
        }
        callFrame->setThisValue(thisValue);
    }

    NAPICallFrame frame(globalObject, callFrame, napi->dataPtr(), newTarget);
    Bun::NapiHandleScope handleScope(uncheckedDowncast<Zig::GlobalObject>(globalObject));

    JSValue ret = toJS(napi->constructor()(napi->env(), frame.toNapi()));
    napi_set_last_error(napi->env(), napi_ok);
    napi->env()->throwPendingException();
    RETURN_IF_EXCEPTION(scope, {});
    if (ret.isEmpty()) {
        ret = jsUndefined();
    }
    if constexpr (ConstructCall) {
        RELEASE_AND_RETURN(scope, JSValue::encode(frame.thisValue()));
    } else {
        RELEASE_AND_RETURN(scope, JSValue::encode(ret));
    }
}

NapiClass* NapiClass::create(VM& vm, napi_env env, const WTF::String& name,
    napi_callback constructor,
    void* data, NapiPrototype* prototype)
{
    NativeExecutable* executable = vm.getHostFunction(
        // for normal call
        NapiClass_ConstructorFunction<false>,
        ImplementationVisibility::Public,
        // for constructor call
        NapiClass_ConstructorFunction<true>, 0, name);
    Structure* structure = env->globalObject()->NapiClassStructure();
    NapiClass* napiClass = new (NotNull, allocateCell<NapiClass>(vm)) NapiClass(vm, executable, env, structure, constructor, data);
    napiClass->finishCreation(vm, prototype);
    return napiClass;
}

void NapiClass::finishCreation(VM& vm, NapiPrototype* prototype)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    auto globalObject = static_cast<Zig::GlobalObject*>(this->globalObject());

    if (!prototype)
        prototype = NapiPrototype::create(vm, globalObject->NapiPrototypeStructure());
    this->putDirect(vm, vm.propertyNames->prototype, prototype, JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    if (!prototype->getDirect(vm, vm.propertyNames->constructor))
        prototype->putDirect(vm, vm.propertyNames->constructor, this, JSC::PropertyAttribute::DontEnum | 0);
}

const ClassInfo NapiClass::s_info = { "Function"_s, &NapiClass::Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NapiClass) };
const ClassInfo NapiPrototype::s_info = { "Object"_s, &NapiPrototype::Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NapiPrototype) };
}
