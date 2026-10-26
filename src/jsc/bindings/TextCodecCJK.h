/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "TextCodec.h"
#include <array>
#include <initializer_list>
#include <optional>

namespace PAL {

class TextCodecCJK final : public TextCodec {
public:
    enum class Encoding : uint8_t { EUC_JP, ISO2022JP, Shift_JIS, EUC_KR, Big5, GBK, GB18030 };
    explicit TextCodecCJK(Encoding);

private:
    void reset() final;
    String decode(std::span<const uint8_t>, bool flush, bool stopOnError, bool& sawError) final;

    enum class SawError : bool { No,
        Yes };
    template<typename ByteParser>
    String decodeCommon(std::span<const uint8_t>&, bool, bool, bool&, const ByteParser&);

    String eucJPDecode(std::span<const uint8_t>&, bool, bool, bool&);
    String iso2022JPDecode(std::span<const uint8_t>&, bool, bool, bool&);
    String shiftJISDecode(std::span<const uint8_t>&, bool, bool, bool&);
    String eucKRDecode(std::span<const uint8_t>&, bool, bool, bool&);
    String big5Decode(std::span<const uint8_t>&, bool, bool, bool&);
    String gbkDecode(std::span<const uint8_t>&, bool, bool, bool&);
    String gb18030Decode(std::span<const uint8_t>&, bool, bool, bool&);
    void prepend(std::initializer_list<uint8_t>);
    uint8_t takeByte(std::span<const uint8_t>&);

    const Encoding m_encoding;

    bool m_jis0212 { false };

    enum class ISO2022JPDecoderState : uint8_t { ASCII,
        Roman,
        Katakana,
        LeadByte,
        TrailByte,
        EscapeStart,
        Escape };
    ISO2022JPDecoderState m_iso2022JPDecoderState { ISO2022JPDecoderState::ASCII };
    ISO2022JPDecoderState m_iso2022JPDecoderOutputState { ISO2022JPDecoderState::ASCII };
    bool m_iso2022JPOutput { false };

    uint8_t m_gb18030First { 0x00 };
    uint8_t m_gb18030Second { 0x00 };
    uint8_t m_gb18030Third { 0x00 };

    uint8_t m_lead { 0x00 };
    // GB18030 restores at most three bytes; the other codecs restore at most two.
    std::array<uint8_t, 3> m_prependedBytes {};
    uint8_t m_prependedByteCount { 0 };
};

} // namespace PAL
