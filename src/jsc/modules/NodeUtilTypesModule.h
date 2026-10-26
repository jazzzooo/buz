#pragma once

#include "BunClientData.h"

using namespace JSC;

namespace Bun::NodeUtilTypes {

bool isNativeError(JSC::JSValue) noexcept;
bool isAnyArrayBuffer(JSC::JSValue) noexcept;
bool isBoxedPrimitive(JSC::JSValue) noexcept;
bool isArrayBufferView(JSC::JSValue) noexcept;
bool isTypedArray(JSC::JSValue) noexcept;

}
