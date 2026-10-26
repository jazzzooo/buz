#pragma once

#include "FetchHeaders.h"
#include "SchemaBindings.h"

namespace WebCore {

using JSFetchHeaders = Bun::BunBindgen_WebCoreHeaders_Headers;

JSC::JSValue getInternalProperties(JSC::VM&, JSC::JSGlobalObject*, JSFetchHeaders*);
RefPtr<FetchHeaders> protectedFetchHeaders(JSC::JSGlobalObject*, JSC::JSValue);

} // namespace WebCore
