#include "BindgenTypePredicates.h"
#include "BunClientData.h"
#include "ErrorPrototype.h"
#include "JSDOMWrapper.h"
#include "NodeUtilTypesModule.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/TopExceptionScope.h>

using namespace JSC;

namespace Bun::NodeUtilTypes {

static JSCell* cell(JSValue value) noexcept
{
    return value.isCell() ? value.asCell() : nullptr;
}

bool isNativeError(JSValue value) noexcept
{
    auto* candidate = cell(value);
    if (!candidate)
        return false;
    if (candidate->type() == ErrorInstanceType)
        return true;

    // ResolveMessage and BuildMessage are error-like wrappers whose native base is not ErrorInstance.
    return bun_bindgen_class_ResolveMessage_ResolveMessage_try_cast_value(candidate)
        || bun_bindgen_class_BuildMessage_BuildMessage_try_cast_value(candidate);
}

bool isAnyArrayBuffer(JSValue value) noexcept
{
    return Bindgen::TypePredicates::isArrayBuffer(value)
        || Bindgen::TypePredicates::isSharedArrayBuffer(value);
}

bool isBoxedPrimitive(JSValue value) noexcept
{
    return Bindgen::TypePredicates::isBooleanObject(value)
        || Bindgen::TypePredicates::isNumberObject(value)
        || Bindgen::TypePredicates::isStringObject(value)
        || Bindgen::TypePredicates::isSymbolObject(value)
        || Bindgen::TypePredicates::isBigIntObject(value);
}

bool isArrayBufferView(JSValue value) noexcept
{
    auto* candidate = cell(value);
    return candidate && candidate->type() >= Int8ArrayType && candidate->type() <= DataViewType;
}

bool isTypedArray(JSValue value) noexcept
{
    auto* candidate = cell(value);
    return candidate && candidate->type() >= Int8ArrayType && candidate->type() <= BigUint64ArrayType;
}

}

bool Bun::Bindgen::Cpp::bunBindgenCpp_NodeUtil_isError(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_NodeUtil_isError_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    if (!args.value || args.value->is_ignored())
        return false;

    auto value = args.value->object();
    if (value.inherits<JSC::ErrorInstance>() || value.asCell()->type() == ErrorInstanceType)
        return true;

    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSObject* object = value.getObject();

    PropertySlot slot(object, PropertySlot::InternalMethodType::VMInquiry, &vm);
    bool has = object->getPropertySlot(globalObject, vm.propertyNames->toStringTagSymbol, slot);
    scope.assertNoException();
    if (has && slot.isValue()) {
        JSValue tagValue = slot.getValue(globalObject, vm.propertyNames->toStringTagSymbol);
        if (tagValue.isString()) {
            String tag = asString(tagValue)->value(globalObject);
            (void)scope.tryClearException();
            if (tag == "Error"_s)
                return true;
        }
    }

    JSValue proto = object->getPrototype(globalObject);
    return proto.isCell()
        && (proto.inherits<JSC::ErrorInstance>()
            || proto.asCell()->type() == ErrorInstanceType
            || proto.inherits<JSC::ErrorPrototype>());
}
