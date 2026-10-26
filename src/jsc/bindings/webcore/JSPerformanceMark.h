#pragma once

// Glue over the generated PerformanceMark wrapper cell. The cell, prototype,
// constructor, conversions, and toJS come from WebCorePerformance.schema.zig;
// wrapper caching resolves through the shared PerformanceEntry owner.

#include "root.h"
#include "SchemaBindingsEngineClasses.h"
#include "PerformanceEntryOwner.h"

namespace WebCore {

using JSPerformanceMark = Bun::BunBindgen_WebCorePerformance_PerformanceMark;

} // namespace WebCore
