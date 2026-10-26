#pragma once

#include "root.h"
#include "ZigGlobalObject.h"

namespace JSC {
class JSGlobalObject;
class JSValue;
}

namespace Bun {

class TTYWrapObject;
class TTYWrapConstructor;
TTYWrapObject* ttyWrapObjectCast(JSC::JSValue);
TTYWrapConstructor* ttyWrapConstructorCast(JSC::JSValue);
bool isTTYWrapObject(JSC::JSValue) noexcept;
bool isTTYWrapConstructor(JSC::JSValue) noexcept;
JSC::JSValue createNodeTTYWrapObject(JSC::JSGlobalObject* globalObject);

}
