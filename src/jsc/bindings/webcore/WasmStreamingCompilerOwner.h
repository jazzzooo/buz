#pragma once

#include <JavaScriptCore/WasmStreamingCompiler.h>
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSWasmStreamingCompilerOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void*, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void*) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, JSC::Wasm::StreamingCompiler*)
{
    static NeverDestroyed<JSWasmStreamingCompilerOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(JSC::Wasm::StreamingCompiler* object)
{
    return object;
}

} // namespace WebCore
