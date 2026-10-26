#pragma once

#include "root.h"

namespace WebCore { class JSVMClientData; }

namespace Bun {
void clearDebuggerCallbacksForVM(WebCore::JSVMClientData&);
}
