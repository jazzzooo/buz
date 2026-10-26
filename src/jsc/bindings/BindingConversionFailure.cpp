#include "config.h"
#include "Bindgen/ConversionFailure.h"
#include "Bindgen/Completion.h"
#include "DOMException.h"
#include "JSDOMException.h"

namespace Bun {

JSC::JSValue createBindingDOMException(JSC::JSGlobalObject& global, WebCore::ExceptionCode code, const WTF::String& message)
{
    auto exception = WebCore::DOMException::create(code, message);
    return WebCore::toJS(&global, static_cast<WebCore::JSDOMGlobalObject*>(&global), exception.get());
}

void Bindgen::raiseBindingOutOfMemory(EngineCallContext& context)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    JSC::throwOutOfMemoryError(&context.globalObject, scope);
}

}
