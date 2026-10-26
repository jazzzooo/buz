#include "root.h"
#include "SchemaBindings.h"
#include "wtf/text/WTFString.h"

#ifdef FUZZILLI_ENABLED
#include "JavaScriptCore/Identifier.h"
#include "JavaScriptCore/JSGlobalObject.h"
#include "ZigGlobalObject.h"
#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sanitizer/asan_interface.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define REPRL_DWFD 103

// Signal handler to ensure output is flushed before crash
static void fuzzilliSignalHandler(int sig)
{
    // Flush all output
    fflush(stdout);
    fflush(stderr);
    fsync(STDOUT_FILENO);
    fsync(STDERR_FILENO);

    // Re-raise the signal with default handler
    signal(sig, SIG_DFL);
    raise(sig);
}

static void functionFuzzilliCrash(int32_t crashType)
{
    fprintf(stdout, "FUZZILLI_CRASH: %d\n", crashType);
    fflush(stdout);

    switch (crashType) {
    case 0:
        std::abort();
        break;
    case 1:
    case 2:
        __builtin_trap();
        break;
    case 3: {
        volatile char* buffer = new char[10];
        buffer[20] = 'x'; // Intentionally exercise ASAN's heap-overflow detection.
        break;
    }
    case 4: {
        volatile char* buffer = new char[10];
        delete[] buffer;
        buffer[0] = 'x'; // Intentionally exercise ASAN's use-after-free detection.
        break;
    }
    case 5: {
        volatile int* ptr = nullptr;
        *ptr = 42;
        break;
    }
    case 6: {
        volatile char buffer[10];
        volatile char* p = const_cast<char*>(buffer);
        p[20] = 'x'; // Intentionally exercise ASAN's stack-overflow detection.
        break;
    }
    case 7: {
        char* buffer = new char[10];
        delete[] buffer;
        delete[] buffer; // Intentionally exercise ASAN's double-free detection.
        break;
    }
    case 8:
        fprintf(stdout, "DEBUG or ASAN is enabled\n");
        fflush(stdout);
        break;
    default:
        std::abort();
        break;
    }
}

static void functionFuzzilliPrint(JSC::JSGlobalObject* globalObject, const WTF::String& output)
{
    static FILE* stream = fdopen(REPRL_DWFD, "w");
    if (!stream)
        return;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto utf8 = output.tryGetUTF8();
    if (!utf8) {
        JSC::throwOutOfMemoryError(globalObject, scope);
        return;
    }
    fwrite(utf8->data(), 1, utf8->length(), stream);
    fputc('\n', stream);
    fflush(stream);
}

// ============================================================================
// Coverage instrumentation for Fuzzilli
// Based on workerd implementation
// Only enabled when ASAN is active
// ============================================================================

#define SHM_SIZE 0x200000
#define MAX_EDGES ((SHM_SIZE - 4) * 8)

struct shmem_data {
    uint32_t num_edges;
    unsigned char edges[];
};

// Atomic intrinsics avoid calling instrumented library functions from coverage callbacks.
static shmem_data* __shmem = nullptr;
static uint32_t* __edges_start = nullptr;
static uint32_t* __edges_stop = nullptr;

// Reset edge guards for next iteration
static void __sanitizer_cov_reset_edgeguards()
{
    if (!__edges_start || !__edges_stop) return;
    uint64_t N = 0;
    for (uint32_t* x = __edges_start; x < __edges_stop && N + 1 < MAX_EDGES; x++) {
        __atomic_store_n(x, static_cast<uint32_t>(++N), __ATOMIC_RELAXED);
    }
}

// Called by the compiler to initialize coverage instrumentation
extern "C" void __sanitizer_cov_trace_pc_guard_init(uint32_t* start, uint32_t* stop)
{
    // Avoid duplicate initialization
    if (start == stop || __atomic_load_n(start, __ATOMIC_RELAXED)) return;

    if (__edges_start != nullptr || __edges_stop != nullptr) {
        fprintf(stderr, "[COV] Coverage instrumentation is only supported for a single module\n");
        _exit(-1);
    }

    __edges_start = start;
    __edges_stop = stop;

    // Map the shared memory region
    shmem_data* shmem = nullptr;
    const char* shm_key = getenv("SHM_ID");
    if (!shm_key) {
        fprintf(stderr, "[COV] no shared memory bitmap available, using malloc\n");
        shmem = static_cast<shmem_data*>(malloc(SHM_SIZE));
        if (!shmem) {
            fprintf(stderr, "[COV] Failed to allocate coverage bitmap\n");
            _exit(-1);
        }
        memset(shmem, 0, SHM_SIZE);
    } else {
        int fd = shm_open(shm_key, O_RDWR, S_IREAD | S_IWRITE);
        if (fd <= -1) {
            fprintf(stderr, "[COV] Failed to open shared memory region: %s\n", strerror(errno));
            _exit(-1);
        }

        shmem = static_cast<shmem_data*>(mmap(0, SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
        close(fd);
        if (shmem == MAP_FAILED) {
            fprintf(stderr, "[COV] Failed to mmap shared memory region\n");
            _exit(-1);
        }
    }

    __sanitizer_cov_reset_edgeguards();
    shmem->num_edges = static_cast<uint32_t>(std::min<size_t>(stop - start, MAX_EDGES - 1));
    __atomic_store_n(&__shmem, shmem, __ATOMIC_RELEASE);
    fprintf(stderr, "[COV] Coverage instrumentation initialized with %u edges\n", shmem->num_edges);
}

// Called by the compiler for each edge
extern "C" void __sanitizer_cov_trace_pc_guard(uint32_t* guard)
{
    auto* shmem = __atomic_load_n(&__shmem, __ATOMIC_ACQUIRE);
    if (!shmem) return;
    uint32_t index = __atomic_exchange_n(guard, 0, __ATOMIC_RELAXED);
    if (!index) return;
    __atomic_fetch_or(&shmem->edges[index / 8], static_cast<unsigned char>(1u << (index % 8)), __ATOMIC_RELAXED);
}

// Register the fuzzilli() function on a Bun global object
namespace Bun {

#define BUN_BINDGEN_OBJECT_SURFACE_FuzzilliGlobal
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_FuzzilliGlobal

void registerFuzzilliFunctions(Zig::GlobalObject* globalObject)
{
    JSC::VM& vm = globalObject->vm();

    // Install signal handlers to ensure output is flushed before crashes
    // This is important for ASAN output to be captured
    signal(SIGABRT, fuzzilliSignalHandler);
    signal(SIGSEGV, fuzzilliSignalHandler);
    signal(SIGILL, fuzzilliSignalHandler);
    signal(SIGFPE, fuzzilliSignalHandler);

    bunBindgenObjectSurface_FuzzilliGlobal_install(vm, globalObject->classInfo(), *globalObject);
}
} // namespace Bun

#endif // FUZZILLI_ENABLED

Bun::Bindgen::FuzzilliCommandKind Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_fuzzilliCommand(
    CppCallContext&,
    const BunBindgenCpp_RuntimeFunctions_fuzzilliCommand_Arguments& args)
{
#ifdef FUZZILLI_ENABLED
    if (args.command == "FUZZILLI_CRASH"_s)
        return FuzzilliCommandKind::crash;
    if (args.command == "FUZZILLI_PRINT"_s)
        return FuzzilliCommandKind::print;
#else
    UNUSED_PARAM(args);
#endif
    return FuzzilliCommandKind::other;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_fuzzilliCrash(
    CppCallContext&,
    const BunBindgenCpp_RuntimeFunctions_fuzzilliCrash_Arguments& args)
{
#ifdef FUZZILLI_ENABLED
    functionFuzzilliCrash(args.type);
#else
    UNUSED_PARAM(args);
#endif
}

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_fuzzilliPrint(
    CppCallContext& context,
    const BunBindgenCpp_RuntimeFunctions_fuzzilliPrint_Arguments& args)
{
#ifdef FUZZILLI_ENABLED
    functionFuzzilliPrint(&context.globalObject, args.message);
#else
    UNUSED_PARAM(context);
    UNUSED_PARAM(args);
#endif
}

void Bun::Bindgen::Cpp::bunBindgenCpp_RuntimeFunctions_jsResetCoverage(
    CppCallContext&,
    const BunBindgenCpp_RuntimeFunctions_jsResetCoverage_Arguments&)
{
#ifdef FUZZILLI_ENABLED
    __sanitizer_cov_reset_edgeguards();
#endif
}
