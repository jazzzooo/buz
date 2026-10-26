/*
 * Copyright (C) 2016 Apple Inc. All rights reserved.
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

#if ENABLE(WEB_CRYPTO)

#include "CryptoKeyFormat.h"
#include "CryptoOperationResult.h"
#include <memory>
#include <variant>
#include <wtf/Ref.h>
#include <wtf/Vector.h>
#include "ExceptionOr.h"

namespace WebCore {

struct JsonWebKey;

class CryptoKey;
class CryptoAlgorithmParameters;

class SubtleCrypto {
public:
    using KeyFormat = CryptoKeyFormat;

    using KeyDataVariant = KeyData;

    static ExceptionOr<Vector<uint8_t>> encrypt(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&& data);
    static ExceptionOr<Vector<uint8_t>> decrypt(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&& data);
    static ExceptionOr<Vector<uint8_t>> sign(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&& data);
    static ExceptionOr<bool> verify(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&& signature, Vector<uint8_t>&& data);
    static ExceptionOr<KeyOrKeyPair> generateKey(const CryptoAlgorithmParameters&, bool extractable, Vector<CryptoKeyUsage>&&);
    static ExceptionOr<Ref<CryptoKey>> deriveKey(const CryptoAlgorithmParameters&, Ref<CryptoKey>&& baseKey, const CryptoAlgorithmParameters& importParams, const CryptoAlgorithmParameters& lengthParams, bool extractable, Vector<CryptoKeyUsage>&&);
    static ExceptionOr<Vector<uint8_t>> deriveBits(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, unsigned length);
    static ExceptionOr<Ref<CryptoKey>> importKey(KeyFormat, KeyDataVariant&&, const CryptoAlgorithmParameters&, bool extractable, Vector<CryptoKeyUsage>&&);
    static ExceptionOr<KeyData> exportKey(KeyFormat, Ref<CryptoKey>&&);
    static ExceptionOr<void> validateWrappingKey(const CryptoAlgorithmParameters&, const CryptoKey&, bool unwrap);
    static ExceptionOr<Vector<uint8_t>> wrapKey(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&&);
    static ExceptionOr<Vector<uint8_t>> unwrapKey(const CryptoAlgorithmParameters&, Ref<CryptoKey>&&, Vector<uint8_t>&&);

private:
    SubtleCrypto() = delete;
};

}

#endif
