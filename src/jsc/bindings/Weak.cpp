#include "root.h"
#include "SchemaBindings.h"
#include "Bindgen/BindingRuntimeDeclarations.h"
#include <JavaScriptCore/StrongInlines.h>
#include "BunClientData.h"
#include <JavaScriptCore/Weak.h>
#include <JavaScriptCore/Strong.h>
#include <wtf/FastMalloc.h>

namespace Bun {

class WeakRef;

class WeakRefOwner final : public JSC::WeakHandleOwner {
public:
    void finalize(JSC::Handle<JSC::Unknown>, void*) final;
};

static JSC::WeakHandleOwner* weakRefOwner()
{
    static NeverDestroyed<WeakRefOwner> owner;
    return &owner.get();
}

class WeakRef {
public:
    WeakRef(JSC::JSObject* object, BunBindgenWeakRefFinalizer* finalizer)
        : m_finalizer(finalizer)
    {
        if (finalizer)
            m_cell = JSC::Weak<JSC::JSObject>(object, weakRefOwner(), this);
        else
            m_cell = JSC::Weak<JSC::JSObject>(object);
    }

    ~WeakRef()
    {
        clear();
    }

    void clear()
    {
        m_finalizer = nullptr;
        m_cell.clear();
    }

    void finalize()
    {
        auto* finalizer = m_finalizer;
        m_finalizer = nullptr;
        if (finalizer)
            Bun::Bindgen::ZigExports::bunBindgenZig_weak_references_weakRefFinalizerRun(finalizer);
    }

    JSC::Weak<JSC::JSObject> m_cell;
    BunBindgenWeakRefFinalizer* m_finalizer { nullptr };
};

void WeakRefOwner::finalize(JSC::Handle<JSC::Unknown>, void* context)
{
    static_cast<WeakRef*>(context)->finalize();
}

}

JSC::JSObject* bindingWeakRefObject(const BindWeakRefHandle* handle) noexcept
{
    auto* reference = reinterpret_cast<const Bun::WeakRef*>(handle);
    return reference->m_cell.get();
}

void Bun::Bindgen::Engine::weakRefRelease(Bun::WeakRef* reference)
{
    reference->~WeakRef();
    WTF::fastFree(reference);
}

Bun::WeakRef* Bun::Bindgen::Engine::bunBindgenEngine_weak_references_weakRefCreate(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_weak_references_weakRefCreate_Arguments& args)
{
    void* allocation = nullptr;
    if (!WTF::tryFastMalloc(sizeof(Bun::WeakRef)).getValue(allocation)) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        JSC::throwOutOfMemoryError(&context.globalObject, scope);
        return nullptr;
    }
    return new (NotNull, allocation) Bun::WeakRef(JSC::asObject(args.value), args.finalizer.value_or(nullptr));
}

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_weak_references_weakRefGet(
    Bun::Bindgen::EngineCallContext&,
    const BunBindgenEngine_weak_references_weakRefGet_Arguments& args)
{
    if (auto* cell = args.reference->m_cell.get())
        return cell;
    return std::nullopt;
}
