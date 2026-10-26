/*
 * Copyright (C) 2020-2021 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY CANON INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL CANON INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "InternalWritableStream.h"

#include "Exception.h"
#include "SchemaBindings.h"
#include "WebCoreJSClientData.h"
#include "ZigGlobalObject.h"

namespace WebCore {

template<auto factory>
static ExceptionOr<JSC::JSValue> invokeWritableStreamFunction(JSC::JSGlobalObject& globalObject, JSC::MarkedArgumentBuffer& arguments)
{
    JSC::VM& vm = globalObject.vm();
    JSC::JSLockHolder lock(vm);

    auto scope = DECLARE_THROW_SCOPE(vm);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(&globalObject, scope);
        return Exception { ExistingExceptionError };
    }
    auto function = factory(defaultGlobalObject(&globalObject));
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    RELEASE_ASSERT(function.isCallable());
    auto result = JSC::profiledCall(&globalObject, JSC::ProfilingReason::API, function, JSC::getCallData(function), JSC::jsUndefined(), arguments);
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });

    return result;
}

ExceptionOr<JSC::JSObject*> InternalWritableStream::createFromUnderlyingSink(JSDOMGlobalObject& globalObject, JSC::MarkedArgumentBuffer& arguments)
{
    auto result = invokeWritableStreamFunction<bun_bindgen_source_function_WritableStreamOperations_create_value>(globalObject, arguments);
    if (result.hasException()) [[unlikely]]
        return result.releaseException();

    auto* stream = result.returnValue().getObject();
    RELEASE_ASSERT(stream);
    return stream;
}

Ref<InternalWritableStream> InternalWritableStream::fromObject(JSDOMGlobalObject& globalObject, JSC::JSObject& object)
{
    return adoptRef(*new InternalWritableStream(globalObject, object));
}

bool InternalWritableStream::locked() const
{
    auto* stream = guarded();
    if (!stream)
        return false;
    auto& vm = stream->vm();
    return !stream->getDirect(vm, builtinNames(vm).writerPrivateName()).isUndefined();
}

JSC::JSValue InternalWritableStream::abort(JSC::JSGlobalObject& globalObject, const Bun::Bindgen::CppAny* reason)
{
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(guardedObject());
    if (reason)
        reason->appendTo(arguments);
    else
        arguments.append(JSC::jsUndefined());
    auto result = invokeWritableStreamFunction<bun_bindgen_source_function_WritableStreamOperations_abort_value>(globalObject, arguments);
    if (result.hasException())
        return {};

    return result.returnValue();
}

JSC::JSValue InternalWritableStream::close(JSC::JSGlobalObject& globalObject)
{
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(guardedObject());
    auto result = invokeWritableStreamFunction<bun_bindgen_source_function_WritableStreamOperations_close_value>(globalObject, arguments);
    if (result.hasException())
        return {};

    return result.returnValue();
}

JSC::JSValue InternalWritableStream::getWriter(JSC::JSGlobalObject& globalObject)
{
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(guardedObject());
    auto result = invokeWritableStreamFunction<bun_bindgen_source_function_WritableStreamOperations_getWriter_value>(globalObject, arguments);
    if (result.hasException())
        return {};

    return result.returnValue();
}

}
