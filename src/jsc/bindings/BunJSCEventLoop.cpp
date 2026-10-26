#include "root.h"
#include "BunClientData.h"
#include "SchemaBindings.h"

#include <JavaScriptCore/VM.h>
#include <JavaScriptCore/Heap.h>
#include <atomic>

static std::atomic_int defaultRemainingRunsUntilSkipReleaseAccess { 10 };

void Bun::Bindgen::Engine::bunBindgenEngine_garbage_collection_setDefaultRemainingRunsUntilSkipReleaseAccess(
    const BunBindgenEngine_garbage_collection_setDefaultRemainingRunsUntilSkipReleaseAccess_Arguments& args)
{
    defaultRemainingRunsUntilSkipReleaseAccess.store(args.value, std::memory_order_relaxed);
}

void Bun::Bindgen::Engine::bunBindgenEngine_virtual_machine_vmOnBeforeWait(
    const BunBindgenEngine_virtual_machine_vmOnBeforeWait_Arguments& args)
{
    auto* vm = args.vm;
    ASSERT(vm);
    const bool previouslyHadAccess = vm->heap.hasHeapAccess();
    // sanity check for debug builds to ensure we're not doing a
    // use-after-free here
    ASSERT(vm->refCount() > 0);
    if (previouslyHadAccess) {

        // Releasing heap access is a balance between:
        // 1. CPU usage
        // 2. Memory usage
        //
        // Not releasing heap access causes benchmarks like
        // https://github.com/oven-sh/bun/pull/14885 to regress due to
        // finalizers not being called quickly enough.
        //
        // Releasing heap access too often causes high idle CPU usage.
        //
        // For the following code:
        // ```
        // setTimeout(() => {}, 10 * 1000)
        // ```
        //
        // command time -v when with defaultRemainingRunsUntilSkipReleaseAccess = 0:
        //
        //   Involuntary context switches: 605
        //
        // command time -v when with defaultRemainingRunsUntilSkipReleaseAccess = 5:
        //
        //   Involuntary context switches: 350
        //
        // command time -v when with defaultRemainingRunsUntilSkipReleaseAccess = 10:
        //
        //   Involuntary context switches: 241
        //
        // Also comapre the #14885 benchmark with different values.
        //
        // The idea here is if you entered JS "recently", running any
        // finalizers that might've been waiting to be run is a good idea.
        // But if you haven't, like if the process is just waiting on I/O
        // then don't bother.
        const int configuredRemainingRunsUntilSkipReleaseAccess = defaultRemainingRunsUntilSkipReleaseAccess.load(std::memory_order_relaxed);

        static thread_local int remainingRunsUntilSkipReleaseAccess = 0;

        // Note: usage of `didEnterVM` in JSC::VM conflicts with Options::validateDFGClobberize
        // We don't need to use that option, so it should be fine.
        if (vm->didEnterVM) {
            vm->didEnterVM = false;
            remainingRunsUntilSkipReleaseAccess = configuredRemainingRunsUntilSkipReleaseAccess;
        }

        if (remainingRunsUntilSkipReleaseAccess-- > 0) {
            // Constellation:
            // > If you are not moving a VM to the different thread, then you can aquire the access and do not need to release
            vm->heap.stopIfNecessary();
            vm->didEnterVM = false;
        }
    }
}
