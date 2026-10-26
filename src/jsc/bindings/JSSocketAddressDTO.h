// The object returned by Bun.serve's .requestIP()
#pragma once
#include "root.h"
#include "JavaScriptCore/JSObjectInlines.h"
#include "ZigGlobalObject.h"

using namespace JSC;

namespace Bun {
namespace JSSocketAddressDTO {

Structure* createStructure(VM& vm, JSGlobalObject* globalObject);
JSObject* create(Zig::GlobalObject* globalObject, JSString* value, int port, bool isIPv6);

} // namespace JSSocketAddressDTO
} // namespace Bun
