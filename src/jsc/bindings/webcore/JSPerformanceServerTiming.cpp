#include "config.h"
#include "SchemaBindings.h"

namespace Bun::Bindgen::Cpp {

WTF::String bunBindgenCpp_PerformanceServerTiming_PerformanceServerTiming_getter_name(
    CppCallContext&,
    const BunBindgenCpp_PerformanceServerTiming_PerformanceServerTiming_getter_name_Arguments& args)
{
    return args.bindingThis.name;
}

double bunBindgenCpp_PerformanceServerTiming_PerformanceServerTiming_getter_duration(
    CppCallContext&,
    const BunBindgenCpp_PerformanceServerTiming_PerformanceServerTiming_getter_duration_Arguments& args)
{
    return args.bindingThis.duration;
}

WTF::String bunBindgenCpp_PerformanceServerTiming_PerformanceServerTiming_getter_description(
    CppCallContext&,
    const BunBindgenCpp_PerformanceServerTiming_PerformanceServerTiming_getter_description_Arguments& args)
{
    return args.bindingThis.description;
}

PerformanceServerTimingJSONDictionaryResult bunBindgenCpp_PerformanceServerTiming_PerformanceServerTiming_method_toJSON(
    CppCallContext&,
    const BunBindgenCpp_PerformanceServerTiming_PerformanceServerTiming_method_toJSON_Arguments& args)
{
    return {
        .name = args.bindingThis.name,
        .duration = args.bindingThis.duration,
        .description = args.bindingThis.description,
    };
}

} // namespace Bun::Bindgen::Cpp
