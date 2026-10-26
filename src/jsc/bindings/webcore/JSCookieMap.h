#pragma once

#include "CookieMap.h"
#include "SchemaBindings.h"

namespace WebCore {

using JSCookieMap = Bun::BunBindgen_WebCoreCookies_CookieMap;

JSC::JSValue getInternalProperties(JSC::VM&, JSC::JSGlobalObject*, JSCookieMap*);
RefPtr<CookieMap> protectedCookieMap(JSC::JSGlobalObject*, JSC::JSValue);

} // namespace WebCore
