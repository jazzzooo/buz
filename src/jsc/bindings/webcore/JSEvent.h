#pragma once

#include "EventOwner.h"
#include "JSDOMWrapper.h"
#include "SchemaBindingsEngineClasses.h"

namespace WebCore {

using JSEvent = Bun::BunBindgen_WebCoreEvents_Event;

} // namespace WebCore

#include "JSEventCustom.h"
