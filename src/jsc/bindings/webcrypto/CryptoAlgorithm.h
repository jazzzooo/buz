/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "CryptoAlgorithmIdentifier.h"
#include "CryptoKeyFormat.h"
#include "CryptoKeyPair.h"
#include "CryptoOperationResult.h"
#include "CryptoKeyUsage.h"
#include "ExceptionOr.h"
#include "JsonWebKey.h"
#include <variant>
#include <wtf/FastMalloc.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>

#if ENABLE(WEB_CRYPTO)

namespace WebCore {

class CryptoAlgorithmParameters;
class CryptoKey;

class CryptoAlgorithm : public ThreadSafeRefCounted<CryptoAlgorithm> {
public:
    virtual ~CryptoAlgorithm() = default;

    virtual CryptoAlgorithmIdentifier identifier() const = 0;

    virtual ExceptionOr<Vector<uint8_t>> encrypt(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&&);
    virtual ExceptionOr<Vector<uint8_t>> decrypt(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&&);
    virtual ExceptionOr<Vector<uint8_t>> sign(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&&);
    virtual ExceptionOr<bool> verify(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&& signature, Vector<uint8_t>&&);
    virtual ExceptionOr<KeyOrKeyPair> generateKey(const CryptoAlgorithmParameters&, bool extractable, CryptoKeyUsageBitmap);
    virtual ExceptionOr<Vector<uint8_t>> deriveBits(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, size_t length);
    // FIXME: https://bugs.webkit.org/show_bug.cgi?id=169262
    virtual ExceptionOr<Ref<CryptoKey>> importKey(CryptoKeyFormat, KeyData&&, const CryptoAlgorithmParameters&, bool extractable, CryptoKeyUsageBitmap);
    virtual ExceptionOr<KeyData> exportKey(CryptoKeyFormat, Ref<CryptoKey>&&);
    virtual ExceptionOr<Vector<uint8_t>> wrapKey(Ref<CryptoKey>&&, Vector<uint8_t>&&);
    virtual ExceptionOr<Vector<uint8_t>> unwrapKey(Ref<CryptoKey>&&, Vector<uint8_t>&&);
    virtual ExceptionOr<size_t> getKeyLength(const CryptoAlgorithmParameters&);
};

} // namespace WebCore

#endif // ENABLE(WEB_CRYPTO)
