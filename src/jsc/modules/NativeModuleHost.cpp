#include "root.h"
#include "SchemaBindings.h"
#include "BunAppModule.h"
#include "NodeBufferModule.h"
#include "NodeStringDecoderModule.h"

namespace Bun {

#define BUN_DEFINE_LAZY_SURFACE_FUNCTION(Module, Function, Callback)                                      \
    JSC::JSValue Bindgen::Cpp::bunBindgenCpp_##Module##_##Function(                                      \
        Bindgen::CppCallContext& context,                                                               \
        const Bindgen::Cpp::BunBindgenCpp_##Module##_##Function##_Arguments& args)                       \
    {                                                                                                   \
        return Callback(context.globalObject.vm(), JSC::asObject(args.bindingThis));                     \
    }

BUN_DEFINE_LAZY_SURFACE_FUNCTION(NativeModuleHost, constructNodeBufferTranscode, Bindgen::constructNodeBufferTranscode)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(NativeModuleHost, constructBunAppResponse, Bindgen::constructBunAppResponse)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(NativeModuleHost, constructNodeStringDecoder, Bindgen::constructNodeStringDecoder)

#undef BUN_DEFINE_LAZY_SURFACE_FUNCTION

} // namespace Bun
