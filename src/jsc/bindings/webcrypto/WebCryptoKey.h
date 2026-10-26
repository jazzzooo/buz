#pragma once

#include "CryptoKey.h"
#include "SchemaBindings.h"

namespace WebCore {

inline CryptoKey& webCryptoKey(BunBindgen_WebCryptoKey_CryptoKey_Native* owner)
{
    return *Bun::Bindgen::ZigExports::bunBindgenZig_WebCryptoKey_nativeKey(owner);
}

inline CryptoKey& webCryptoKey(JSC::JSValue value)
{
    auto* owner = bun_bindgen_class_WebCryptoKey_CryptoKey_try_cast_value(value);
    RELEASE_ASSERT(owner);
    return webCryptoKey(owner);
}

}
