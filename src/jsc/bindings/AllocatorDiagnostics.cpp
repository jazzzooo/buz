#include "root.h"
#include "SchemaBindings.h"

#if OS(DARWIN) && BUN_DEBUG
#include <malloc/malloc.h>
#include <cstdio>
#endif

void Bun::Bindgen::Engine::bunBindgenEngine_UnsafeObject_dumpMallocZoneStats(
    const BunBindgenEngine_UnsafeObject_dumpMallocZoneStats_Arguments&)
{
#if OS(DARWIN) && BUN_DEBUG
    vm_address_t* zones = nullptr;
    unsigned count = 0;
    if (malloc_get_all_zones(mach_task_self(), nullptr, &zones, &count) != KERN_SUCCESS)
        return;
    for (unsigned index = 0; index < count; ++index) {
        auto* zone = reinterpret_cast<malloc_zone_t*>(zones[index]);
        const char* name = malloc_get_zone_name(zone);
        if (!name)
            continue;
        malloc_statistics_t stats {};
        malloc_zone_statistics(zone, &stats);
        printf("%s:\n", name);
        printf("  blocks_in_use:   %u\n", stats.blocks_in_use);
        printf("  size_in_use:     %zu\n", stats.size_in_use);
        printf("  max_size_in_use: %zu\n", stats.max_size_in_use);
        printf("  size_allocated:  %zu\n\n", stats.size_allocated);
    }
#endif
}
