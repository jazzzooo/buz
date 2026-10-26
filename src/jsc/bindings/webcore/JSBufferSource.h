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

#include "JSDOMWrapperCache.h"
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>

namespace WebCore {

inline JSC::JSValue toJS(JSC::JSGlobalObject*, JSC::JSGlobalObject* globalObject, JSC::ArrayBuffer& buffer)
{
    if (auto result = getCachedWrapper(currentWorld(*globalObject), buffer))
        return result;

    // The JSArrayBuffer::create function will register the wrapper in finishCreation.
    return JSC::JSArrayBuffer::create(JSC::getVM(globalObject), globalObject->arrayBufferStructure(buffer.sharingMode()), &buffer);
}

inline JSC::JSValue toJS(JSC::JSGlobalObject* lexicalGlobalObject, JSC::JSGlobalObject* globalObject, JSC::ArrayBufferView& view)
{
    return view.wrap(lexicalGlobalObject, globalObject);
}

inline JSC::JSValue toJS(JSC::JSGlobalObject* lexicalGlobalObject, JSC::JSGlobalObject* globalObject, JSC::ArrayBuffer* buffer)
{
    if (!buffer)
        return JSC::jsNull();
    return toJS(lexicalGlobalObject, globalObject, *buffer);
}

inline JSC::JSValue toJS(JSC::JSGlobalObject* lexicalGlobalObject, JSC::JSGlobalObject* globalObject, JSC::ArrayBufferView* view)
{
    if (!view)
        return JSC::jsNull();
    return toJS(lexicalGlobalObject, globalObject, *view);
}

inline RefPtr<JSC::ArrayBufferView> toPossiblySharedArrayBufferView(JSC::VM&, JSC::JSValue value)
{
    auto* wrapper = dynamicDowncast<JSC::JSArrayBufferView>(value);
    if (!wrapper)
        return nullptr;
    return wrapper->possiblySharedImpl();
}

} // namespace WebCore
