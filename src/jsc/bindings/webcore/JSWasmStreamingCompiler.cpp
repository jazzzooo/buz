#include "config.h"
#include "JSWasmStreamingCompiler.h"

#include "JSDOMWrapperCache.h"

namespace WebCore {

using namespace JSC;

bool JSWasmStreamingCompilerOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void*, JSC::AbstractSlotVisitor&, ASCIILiteral*)
{
    return false;
}

void JSWasmStreamingCompilerOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSWasmStreamingCompiler*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun::Bindgen::Cpp {

using namespace JSC;
using namespace WebCore;

void bunBindgenCpp_WebCoreStreams_WasmStreamingCompiler_method_addBytes(
    CppEngineCallContext<JSWasmStreamingCompiler>& ctx,
    const BunBindgenCpp_WebCoreStreams_WasmStreamingCompiler_method_addBytes_Arguments& args)
{
    ctx.wrapped().addBytes({ args.chunk.unsafePtr("The streaming parser consumes this chunk before the entry frame releases its lease"_s), args.chunk.size() });
}

void bunBindgenCpp_WebCoreStreams_WasmStreamingCompiler_method_finalize(
    CppEngineCallContext<JSWasmStreamingCompiler>& ctx,
    const BunBindgenCpp_WebCoreStreams_WasmStreamingCompiler_method_finalize_Arguments&)
{
    ctx.wrapped().finalize(&ctx.globalObject);
}

void bunBindgenCpp_WebCoreStreams_WasmStreamingCompiler_method_fail(
    CppEngineCallContext<JSWasmStreamingCompiler>& ctx,
    const BunBindgenCpp_WebCoreStreams_WasmStreamingCompiler_method_fail_Arguments& args)
{
    ctx.wrapped().fail(&ctx.globalObject, args.error);
}

void bunBindgenCpp_WebCoreStreams_WasmStreamingCompiler_method_cancel(
    CppEngineCallContext<JSWasmStreamingCompiler>& ctx,
    const BunBindgenCpp_WebCoreStreams_WasmStreamingCompiler_method_cancel_Arguments&)
{
    ctx.wrapped().cancel();
}

} // namespace Bun::Bindgen::Cpp
