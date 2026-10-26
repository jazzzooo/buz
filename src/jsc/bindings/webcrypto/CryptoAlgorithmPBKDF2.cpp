/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
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
#include "CryptoAlgorithmPBKDF2.h"

#if ENABLE(WEB_CRYPTO)

#include "CryptoAlgorithmPbkdf2Params.h"
#include "CryptoKeyRaw.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <wtf/CrossThreadCopier.h>

namespace WebCore {

Ref<CryptoAlgorithm> CryptoAlgorithmPBKDF2::create()
{
    return adoptRef(*new CryptoAlgorithmPBKDF2);
}

CryptoAlgorithmIdentifier CryptoAlgorithmPBKDF2::identifier() const
{
    return s_identifier;
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmPBKDF2::deriveBits(const CryptoAlgorithmParameters& parameters, Ref<CryptoKey>&& baseKey, size_t length)
{
    if (!length || length % 8) {
        return Exception { OperationError, ""_s };
    }

    const auto& operation_parameters = downcast<CryptoAlgorithmPbkdf2Params>(parameters);
    return platformDeriveBits(operation_parameters, downcast<CryptoKeyRaw>(baseKey.get()), length);
}

ExceptionOr<Ref<CryptoKey>> CryptoAlgorithmPBKDF2::importKey(CryptoKeyFormat format, KeyData&& data, const CryptoAlgorithmParameters& parameters, bool extractable, CryptoKeyUsageBitmap usages)
{
    if (format != CryptoKeyFormat::Raw) {
        return Exception { NotSupportedError, ""_s };
    }
    if (usages & (CryptoKeyUsageEncrypt | CryptoKeyUsageDecrypt | CryptoKeyUsageSign | CryptoKeyUsageVerify | CryptoKeyUsageWrapKey | CryptoKeyUsageUnwrapKey)) {
        return Exception { SyntaxError, ""_s };
    }
    if (extractable) {
        return Exception { SyntaxError, ""_s };
    }

    return Ref<CryptoKey> { CryptoKeyRaw::create(parameters.identifier, WTF::move(std::get<Vector<uint8_t>>(data)), usages) };
}

ExceptionOr<size_t> CryptoAlgorithmPBKDF2::getKeyLength(const CryptoAlgorithmParameters&)
{
    return 0;
}

} // namespace WebCore

#endif // ENABLE(WEB_CRYPTO)
