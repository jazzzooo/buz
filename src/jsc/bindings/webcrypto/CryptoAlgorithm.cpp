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

#include "config.h"
#include "CryptoAlgorithm.h"

#if ENABLE(WEB_CRYPTO)

namespace WebCore {

ExceptionOr<Vector<uint8_t>> CryptoAlgorithm::encrypt(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&&)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithm::decrypt(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&&)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithm::sign(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&&)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<bool> CryptoAlgorithm::verify(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&&, Vector<uint8_t>&&)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<KeyOrKeyPair> CryptoAlgorithm::generateKey(const CryptoAlgorithmParameters&, bool, CryptoKeyUsageBitmap)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithm::deriveBits(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, size_t)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<Ref<CryptoKey>> CryptoAlgorithm::importKey(CryptoKeyFormat, KeyData&&, const CryptoAlgorithmParameters&, bool, CryptoKeyUsageBitmap)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<KeyData> CryptoAlgorithm::exportKey(CryptoKeyFormat, Ref<CryptoKey>&&)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithm::wrapKey(Ref<CryptoKey>&&, Vector<uint8_t>&&)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithm::unwrapKey(Ref<CryptoKey>&&, Vector<uint8_t>&&)
{
    return Exception { NotSupportedError, ""_s };
}

ExceptionOr<size_t> CryptoAlgorithm::getKeyLength(const CryptoAlgorithmParameters&)
{
    return Exception { NotSupportedError };
}

}

#endif
