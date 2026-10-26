#include "config.h"
#include "JSEventEmitter.h"

namespace Bun {

template<typename Visitor>
void BunBindgen_WebCoreEvents_EventEmitter::visitAdditionalChildren(Visitor& visitor)
{
    wrapped().eventListenerMap().visitJSEventListeners(visitor);
}

template void BunBindgen_WebCoreEvents_EventEmitter::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCoreEvents_EventEmitter::visitAdditionalChildren(JSC::SlotVisitor&);

} // namespace Bun
