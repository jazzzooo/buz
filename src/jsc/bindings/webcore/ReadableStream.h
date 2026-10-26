/*
 * Copyright (C) 2017-2020 Apple Inc. All rights reserved.
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
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "ExceptionOr.h"
#include "JSDOMBinding.h"
#include "JSDOMGuardedObject.h"
#include <JavaScriptCore/JSObject.h>

namespace WebCore {

WEBCORE_EXPORT bool isReadableStream(JSC::JSValue) noexcept;
WEBCORE_EXPORT JSC::JSValue readableStreamNativePtr(JSC::JSObject&);
WEBCORE_EXPORT int32_t readableStreamNativeType(JSC::JSObject&);
WEBCORE_EXPORT bool readableStreamIsTransferred(JSC::JSObject&);
WEBCORE_EXPORT bool readableStreamIsDisturbed(JSC::JSObject&);
WEBCORE_EXPORT void setReadableStreamNativePtr(JSC::JSGlobalObject&, JSC::JSObject&, JSC::JSValue);
WEBCORE_EXPORT void setReadableStreamNativeType(JSC::JSGlobalObject&, JSC::JSObject&, int32_t);
WEBCORE_EXPORT void setReadableStreamTransferred(JSC::JSGlobalObject&, JSC::JSObject&);
WEBCORE_EXPORT void setReadableStreamDisturbed(JSC::JSGlobalObject&, JSC::JSObject&, bool);

class ReadableStream final : public DOMGuarded<JSC::JSObject> {
public:
    static Ref<ReadableStream> create(JSDOMGlobalObject& globalObject, JSC::JSObject& readableStream) { return adoptRef(*new ReadableStream(globalObject, readableStream)); }

    WEBCORE_EXPORT static bool isDisturbed(JSC::JSGlobalObject*, JSC::JSObject*);
    WEBCORE_EXPORT static bool isLocked(JSC::JSGlobalObject*, JSC::JSObject*);
    bool isLocked() const;
    bool isDisturbed() const;

    JSC::JSObject* readableStream() const { return guarded(); }

private:
    ReadableStream(JSDOMGlobalObject& globalObject, JSC::JSObject& readableStream)
        : DOMGuarded<JSC::JSObject>(globalObject, readableStream)
    {
    }
};

inline JSC::JSValue toJS(JSC::JSGlobalObject*, JSC::JSGlobalObject*, ReadableStream* stream)
{
    return stream ? stream->readableStream() : JSC::jsUndefined();
}

inline JSC::JSValue toJS(JSC::JSGlobalObject*, JSC::JSGlobalObject*, ReadableStream& stream)
{
    return stream.readableStream();
}

inline JSC::JSValue toJSNewlyCreated(JSC::JSGlobalObject*, JSDOMGlobalObject*, Ref<ReadableStream>&& stream)
{
    return stream->readableStream();
}

}
