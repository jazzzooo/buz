#pragma once

#include "root.h"
#include "ResolvedSource.h"
#include <optional>
#include <wtf/text/WTFString.h>

#include <JavaScriptCore/JSCInlines.h>
#include "BunClientData.h"

namespace Zig {
class GlobalObject;
}

namespace JSC {
class JSPromise;
}

namespace Bun {
using namespace JSC;

class JSCommonJSModule;

bool isBunTest();

JSValue fetchESMSourceCodeSync(
    Zig::GlobalObject* globalObject,
    JSString* specifierJS,
    ResolvedSourceResult& res,
    const WTF::String& specifier,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute);

JSValue fetchESMSourceCodeAsync(
    Zig::GlobalObject* globalObject,
    JSString* specifierJS,
    ResolvedSourceResult& res,
    const WTF::String& specifier,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute);

JSValue fetchCommonJSModule(
    Zig::GlobalObject* globalObject,
    JSCommonJSModule* moduleObject,
    JSValue specifierValue,
    const WTF::String& specifier,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute);

template<bool isExtension>
JSValue fetchCommonJSModuleNonBuiltin(
    void* bunVM,
    JSC::VM& vm,
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier,
    JSC::JSValue specifierValue,
    const WTF::String& referrer,
    const std::optional<WTF::String>& typeAttribute,
    ResolvedSourceResult& res,
    JSCommonJSModule* target,
    BunLoaderType forceLoaderType,
    JSC::ThrowScope& scope);

JSValue resolveAndFetchBuiltinModule(
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier);

JSValue fetchBuiltinModuleWithoutResolution(
    Zig::GlobalObject* globalObject,
    const WTF::String& specifier,
    ResolvedSourceResult& res);

} // namespace Bun
