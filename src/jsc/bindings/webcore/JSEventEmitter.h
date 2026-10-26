#pragma once

#include "EventEmitterOwner.h"
#include "JSDOMWrapper.h"
#include "SchemaBindingsEngineClasses.h"
#include <JavaScriptCore/Snippet.h>

namespace WebCore {

using JSEventEmitter = Bun::BunBindgen_WebCoreEvents_EventEmitter;

} // namespace WebCore
