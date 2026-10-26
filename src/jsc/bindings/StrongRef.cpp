#include "root.h"
#include "SchemaBindings.h"
#include "StrongRef.h"
#include "Bindgen/NativeResult.h"
#include <JavaScriptCore/StrongInlines.h>
#include <limits>

static thread_local int32_t rootAllocationFailureCountdown = -1;

static bool failRootAllocation()
{
    if (rootAllocationFailureCountdown < 0)
        return false;
    return rootAllocationFailureCountdown-- == 0;
}

Bun::StrongRefStorage::StrongRefStorage(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
    : m_global(globalObject->vm(), globalObject)
    , m_value(globalObject->vm(), value)
{
    RELEASE_ASSERT(!value.isEmpty());
}

static Bun::StrongRefStorage* allocateStrongRef(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    void* allocation = nullptr;
    if (failRootAllocation() || !WTF::tryFastMalloc(sizeof(Bun::StrongRefStorage)).getValue(allocation))
        return nullptr;
    auto* reference = new (NotNull, allocation) Bun::StrongRefStorage(globalObject, value);
    reference->adopted();
    return reference;
}

Bun::StrongRefStorage* Bun::createStrongRef(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (vm.hasExceptionsAfterHandlingTraps())
        return nullptr;
    if (auto* reference = allocateStrongRef(globalObject, value))
        return reference;
    JSC::throwOutOfMemoryError(globalObject, scope);
    return nullptr;
}

void Bun::Bindgen::Engine::bunBindgenEngine_strong_references_strongRefSetAllocationFailureCountdown(
    Bun::Bindgen::EngineCallContext&,
    const Bun::Bindgen::Engine::BunBindgenEngine_strong_references_strongRefSetAllocationFailureCountdown_Arguments& args)
{
    rootAllocationFailureCountdown = args.countdown;
}

Bun::Bindgen::NativeAllocationResult<Bun::StrongRefStorage*> Bun::Bindgen::Engine::bunBindgenEngine_strong_references_strongRefCreate(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_strong_references_strongRefCreate_Arguments& args)
{
    if (auto* reference = allocateStrongRef(&context.globalObject, args.value))
        return reference;
    return Bun::Bindgen::nativeAllocationFailure();
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_strong_references_strongRefGet(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_strong_references_strongRefGet_Arguments& args)
{
    RELEASE_ASSERT(&args.reference->globalObject()->vm() == &context.globalObject.vm());
    return args.reference->value();
}

Bun::StrongRefStorage* Bun::Bindgen::Engine::bunBindgenEngine_strong_references_strongRefClone(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_strong_references_strongRefClone_Arguments& args)
{
    RELEASE_ASSERT(&args.reference->globalObject()->vm() == &context.globalObject.vm());
    RELEASE_ASSERT(args.reference->refCount() != std::numeric_limits<uint32_t>::max());
    args.reference->ref();
    return args.reference;
}

bool Bun::Bindgen::Engine::bunBindgenEngine_strong_references_strongRefBelongsToCurrentVM(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_strong_references_strongRefBelongsToCurrentVM_Arguments& args)
{
    return &args.reference->globalObject()->vm() == &context.globalObject.vm();
}

bool Bun::Bindgen::Engine::bunBindgenEngine_strong_references_strongRefsShareVM(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_strong_references_strongRefsShareVM_Arguments& args)
{
    RELEASE_ASSERT(&args.left->globalObject()->vm() == &context.globalObject.vm());
    return &args.left->globalObject()->vm() == &args.right->globalObject()->vm();
}

void Bun::Bindgen::Engine::strongRefRelease(Bun::StrongRefStorage* reference)
{
    reference->deref();
}
