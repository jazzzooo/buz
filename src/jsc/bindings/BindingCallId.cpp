#include "SchemaBindingsWire.h"
#include <cstdlib>

extern "C" uint64_t bun_bindgen_take_call_id() noexcept
{
    static thread_local constinit uint64_t next { 1 };
    const uint64_t result = next++;
    if (result == 0)
        std::abort();
    return result;
}
