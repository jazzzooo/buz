#pragma once

#include "root.h"

#include "../bindings/JSBuffer.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"

namespace Bun::Bindgen {
using namespace WebCore;
using namespace JSC;

inline constexpr size_t NodeBufferMaxLength = ::Bun::Buffer::kMaxLength;
inline constexpr size_t NodeBufferMaxStringLength = ::Bun::Buffer::kStringMaxLength;

inline JSC::JSValue constructNodeBufferTranscode(JSC::VM& vm, JSC::JSObject* object)
{
    auto* globalObject = ::defaultGlobalObject(object->globalObject());
    auto* transcode = InternalFunction::createFunctionThatMasqueradesAsUndefined(vm, globalObject, 1, "transcode"_s, bun_bindgen_host_GlobalObjectHost_jsFunctionNotImplemented);
    return transcode;
}

} // namespace Bun::Bindgen
