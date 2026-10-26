#pragma once

// Glue over the generated DOMException wrapper cell. The cell, prototype,
// constructor, legacy code constants, conversions, and toJS come from
// WebCoreDOMException.schema.zig; this header names the cell and carries the
// wrapper-owner contract.

#include "root.h"
#include "SchemaBindingsEngineClasses.h"
#include "DOMExceptionOwner.h"

namespace WebCore {

using JSDOMException = Bun::BunBindgen_WebCoreDOMException_DOMException;

} // namespace WebCore
