#pragma once

#include <JavaScriptCore/JSCJSValue.h>
#include <optional>

namespace JSC {
class JSGlobalObject;
class JSObject;
class JSPromise;
class ThrowScope;
}

namespace Bun {
std::optional<JSC::JSValue> extractErrorValue(JSC::JSValue);
void attachAsyncStackFromPromise(JSC::JSGlobalObject*, JSC::JSValue error, JSC::JSPromise*);
}

namespace Bun::Bindgen {
JSC::JSObject* createBindingOutOfMemoryError(JSC::JSGlobalObject*);
void throwBindingOutOfMemoryError(JSC::JSGlobalObject*, JSC::ThrowScope&);
}
