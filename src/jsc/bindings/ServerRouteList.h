#pragma once

#include "root.h"

namespace Zig {
class GlobalObject;
}

namespace Bun {
class ServerRouteList;
ServerRouteList* serverRouteListCast(JSC::JSValue);
bool isServerRouteList(JSC::JSValue) noexcept;
JSC::Structure* createServerRouteListStructure(JSC::VM&, Zig::GlobalObject*);
JSC::JSObject* createJSBunRequestParamsPrototype(JSC::VM&, Zig::GlobalObject*);
}
