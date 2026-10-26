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

#include <cstdint>
#include <wtf/text/WTFString.h>

namespace WebCore {

template<typename T>
struct IDLType {
    using ImplementationType = T;
};

struct IDLBoolean : IDLType<bool> {
};

template<typename IntegerType> struct IDLInteger : IDLType<IntegerType> {
};
struct IDLByte : IDLInteger<int8_t> {
};
struct IDLOctet : IDLInteger<uint8_t> {
};
struct IDLShort : IDLInteger<int16_t> {
};
struct IDLUnsignedShort : IDLInteger<uint16_t> {
};
struct IDLLong : IDLInteger<int32_t> {
};
struct IDLUnsignedLong : IDLInteger<uint32_t> {
};
struct IDLLongLong : IDLInteger<int64_t> {
};
struct IDLUnsignedLongLong : IDLInteger<uint64_t> {
};

template<typename T> struct IDLClampAdaptor : IDLInteger<typename T::ImplementationType> {
};

struct IDLUnrestrictedDouble : IDLType<double> {
};

struct IDLDOMString : IDLType<String> {
};
struct IDLByteString : IDLType<String> {
};
struct IDLUSVString : IDLType<String> {
};

} // namespace WebCore
