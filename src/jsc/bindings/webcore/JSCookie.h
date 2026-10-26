#pragma once

#include "Cookie.h"
#include "SchemaBindings.h"

namespace WebCore {

using JSCookie = Bun::BunBindgen_WebCoreCookies_Cookie;

JSC::JSValue getInternalProperties(JSC::VM&, JSC::JSGlobalObject*, JSCookie*);
RefPtr<Cookie> protectedCookie(JSC::JSGlobalObject*, JSC::JSValue);

} // namespace WebCore
