#pragma once

#include "root.h"
#include "BakeAdditionsToGlobalObject.h"
#include "ZigGlobalObject.h"

namespace Bun::Bindgen {

inline JSC::JSValue constructBunAppResponse(JSC::VM&, JSC::JSObject* object)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(object->globalObject());
    return globalObject->bakeAdditions().JSBakeResponseConstructor(globalObject);
}

} // namespace Bun::Bindgen
