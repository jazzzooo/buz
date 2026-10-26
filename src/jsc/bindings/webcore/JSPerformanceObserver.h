#pragma once

// Glue over the generated PerformanceObserver wrapper cell. The cell,
// prototype, constructor, statics, conversions, and toJS come from
// WebCorePerformance.schema.zig; this header names the cell and carries the
// wrapper-owner contract.

#include "root.h"
#include "SchemaBindingsEngineClasses.h"
#include "PerformanceObserverOwner.h"

namespace WebCore {

using JSPerformanceObserver = Bun::BunBindgen_WebCorePerformance_PerformanceObserver;

} // namespace WebCore
