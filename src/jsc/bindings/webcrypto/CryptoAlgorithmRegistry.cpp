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
#include "CryptoAlgorithmRegistry.h"

#if ENABLE(WEB_CRYPTO)

#include "CryptoAlgorithmAES_CBC.h"
#include "CryptoAlgorithmAES_CFB.h"
#include "CryptoAlgorithmAES_CTR.h"
#include "CryptoAlgorithmAES_GCM.h"
#include "CryptoAlgorithmAES_KW.h"
#include "CryptoAlgorithmECDH.h"
#include "CryptoAlgorithmECDSA.h"
#include "CryptoAlgorithmHKDF.h"
#include "CryptoAlgorithmHMAC.h"
#include "CryptoAlgorithmPBKDF2.h"
#include "CryptoAlgorithmRSAES_PKCS1_v1_5.h"
#include "CryptoAlgorithmRSASSA_PKCS1_v1_5.h"
#include "CryptoAlgorithmRSA_OAEP.h"
#include "CryptoAlgorithmRSA_PSS.h"
#include "CryptoAlgorithmEd25519.h"
#include "CryptoAlgorithmX25519.h"

namespace WebCore {

String CryptoAlgorithmRegistry::name(CryptoAlgorithmIdentifier identifier)
{
    if (identifier == CryptoAlgorithmIdentifier::None) return {};
    auto name = Bun::Bindgen::enumerationName(identifier);
    return String::fromUTF8(std::span { name.data(), name.size() });
}

RefPtr<CryptoAlgorithm> CryptoAlgorithmRegistry::create(CryptoAlgorithmIdentifier identifier)
{
    switch (identifier) {
    case CryptoAlgorithmIdentifier::AES_CBC:
        return CryptoAlgorithmAES_CBC::create();
    case CryptoAlgorithmIdentifier::AES_CFB:
        return CryptoAlgorithmAES_CFB::create();
    case CryptoAlgorithmIdentifier::AES_CTR:
        return CryptoAlgorithmAES_CTR::create();
    case CryptoAlgorithmIdentifier::AES_GCM:
        return CryptoAlgorithmAES_GCM::create();
    case CryptoAlgorithmIdentifier::AES_KW:
        return CryptoAlgorithmAES_KW::create();
    case CryptoAlgorithmIdentifier::ECDH:
        return CryptoAlgorithmECDH::create();
    case CryptoAlgorithmIdentifier::ECDSA:
        return CryptoAlgorithmECDSA::create();
    case CryptoAlgorithmIdentifier::HKDF:
        return CryptoAlgorithmHKDF::create();
    case CryptoAlgorithmIdentifier::HMAC:
        return CryptoAlgorithmHMAC::create();
    case CryptoAlgorithmIdentifier::PBKDF2:
        return CryptoAlgorithmPBKDF2::create();
    case CryptoAlgorithmIdentifier::RSAES_PKCS1_v1_5:
        return CryptoAlgorithmRSAES_PKCS1_v1_5::create();
    case CryptoAlgorithmIdentifier::RSASSA_PKCS1_v1_5:
        return CryptoAlgorithmRSASSA_PKCS1_v1_5::create();
    case CryptoAlgorithmIdentifier::RSA_OAEP:
        return CryptoAlgorithmRSA_OAEP::create();
    case CryptoAlgorithmIdentifier::RSA_PSS:
        return CryptoAlgorithmRSA_PSS::create();
    case CryptoAlgorithmIdentifier::Ed25519:
        return CryptoAlgorithmEd25519::create();
    case CryptoAlgorithmIdentifier::X25519:
        return CryptoAlgorithmX25519::create();
    default:
        return nullptr;
    }
}

}

#endif
