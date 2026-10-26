#pragma once

#include "DOMFormData.h"
#include "SchemaBindings.h"

namespace WebCore {

using JSDOMFormData = Bun::BunBindgen_WebCoreFormData_FormData;

RefPtr<DOMFormData> protectedFormData(JSC::JSGlobalObject*, JSC::JSValue);
JSC::JSValue getInternalProperties(JSC::VM&, JSC::JSGlobalObject*, JSDOMFormData*);

} // namespace WebCore
