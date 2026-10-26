#pragma once

#include "DOMURL.h"
#include "SchemaBindings.h"

namespace WebCore {

using JSDOMURL = Bun::BunBindgen_WebCoreURL_URL;

RefPtr<DOMURL> protectedDOMURL(JSC::JSGlobalObject*, JSC::JSValue);

} // namespace WebCore
