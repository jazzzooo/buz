#pragma once

#include <JavaScriptCore/JSCJSValue.h>

namespace Bun::Bindgen::Custom {

bool bunBindgenIsWritableStream(JSC::JSValue) noexcept;
bool bunBindgenIsTransformStream(JSC::JSValue) noexcept;
bool bunBindgenIsArrayBuffer(JSC::JSValue) noexcept;
bool bunBindgenIsCompressionStream(JSC::JSValue) noexcept;
bool bunBindgenIsDecompressionStream(JSC::JSValue) noexcept;
bool bunBindgenIsSubtleCrypto(JSC::JSValue) noexcept;

}
