#pragma once

#include "root.h"

namespace Bun {

JSC::JSObject* createBunObject(JSC::VM& vm, JSC::JSObject* globalObject);

JSC::JSObject* BunShell(JSC::JSGlobalObject* globalObject);
JSC::JSValue ShellError(JSC::JSGlobalObject* globalObject);

}
