#include "../bindings/JSStringDecoder.h"
#include "../bindings/ZigGlobalObject.h"
#include <JavaScriptCore/JSGlobalObject.h>

namespace Bun::Bindgen {

inline JSC::JSValue constructNodeStringDecoder(JSC::VM&, JSC::JSObject* object)
{
    return ::defaultGlobalObject(object->globalObject())->JSStringDecoder();
}

} // namespace Bun::Bindgen
