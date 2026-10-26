#include "root.h"
#include "SchemaBindings.h"
#include "helpers.h"
#include "BunCPUProfiler.h"
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/VM.h>

namespace Bun::Bindgen::Cpp {

void bunBindgenCpp_InspectorProfiler_startCPUProfiler(
    CppCallContext& context,
    const BunBindgenCpp_InspectorProfiler_startCPUProfiler_Arguments&)
{
    Bun::startCPUProfiler(context.globalObject.vm());
}

WTF::String bunBindgenCpp_InspectorProfiler_stopCPUProfiler(
    CppCallContext& context,
    const BunBindgenCpp_InspectorProfiler_stopCPUProfiler_Arguments&)
{
    auto& vm = context.globalObject.vm();
    WTF::String result;
    Bun::stopCPUProfiler(vm, &result, nullptr);
    return result;
}

void bunBindgenCpp_InspectorProfiler_setCPUSamplingInterval(
    CppCallContext&,
    const BunBindgenCpp_InspectorProfiler_setCPUSamplingInterval_Arguments& args)
{
    Bun::setSamplingInterval(args.interval);
}

bool bunBindgenCpp_InspectorProfiler_isCPUProfilerRunning(
    CppCallContext&,
    const BunBindgenCpp_InspectorProfiler_isCPUProfilerRunning_Arguments&)
{
    return Bun::isCPUProfilerRunning();
}

}
