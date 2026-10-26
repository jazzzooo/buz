#pragma once

#include "SchemaBindings.h"
#include "URLSearchParams.h"

namespace WebCore {

using JSURLSearchParams = Bun::BunBindgen_WebCoreURL_URLSearchParams;

RefPtr<URLSearchParams> protectedURLSearchParams(JSC::JSGlobalObject*, JSC::JSValue);
JSC::JSValue getInternalProperties(JSC::VM&, JSC::JSGlobalObject*, JSURLSearchParams*);

} // namespace WebCore
