#include "root.h"
#include "SchemaBindings.h"
#include "ExceptionOr.h"
#include "MessagePort.h"
#include "SerializedScriptValue.h"
#include "JSDOMExceptionHandling.h"

using namespace JSC;
using namespace WebCore;

Bun::Bindgen::Engine::BunBindgenEngine_structured_serialization_serializeJSValue_Return Bun::Bindgen::Engine::bunBindgenEngine_structured_serialization_serializeJSValue(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_structured_serialization_serializeJSValue_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    Vector<JSC::Strong<JSC::JSObject>> transferList;
    Vector<RefPtr<MessagePort>> dummyPorts;
    auto forTransfer = args.for_cross_process_transfer ? SerializationForCrossProcessTransfer::Yes : SerializationForCrossProcessTransfer::No;
    ExceptionOr<Ref<SerializedScriptValue>> serialized = SerializedScriptValue::create(*globalObject, args.value, WTF::move(transferList), dummyPorts, SerializationForStorage::Yes, SerializationContext::Default, forTransfer);

    EXCEPTION_ASSERT(!!scope.exception() == serialized.hasException());
    if (serialized.hasException()) {
        WebCore::propagateException(*globalObject, scope, serialized.releaseException());
        RELEASE_AND_RETURN(scope, {});
    }

    return &serialized.releaseReturnValue().leakRef();
}

std::span<const uint8_t> Bun::Bindgen::Engine::serializedScriptValueBytes(SerializedScriptValue* value)
{
    RELEASE_ASSERT(value);
    return value->wireBytes().span();
}

void Bun::Bindgen::Engine::releaseSerializedScriptValue(SerializedScriptValue* value)
{
    RELEASE_ASSERT(value);
    value->deref();
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_structured_serialization_deserializeJSValue(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_structured_serialization_deserializeJSValue_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    return SerializedScriptValue::fromBytes(*globalObject, args.data);
}
