#pragma once

#include "BindingRuntimeDeclarations.h"
#include "BunClientData.h"
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/Weak.h>
#include <JavaScriptCore/WeakHandleOwner.h>
#include <JavaScriptCore/WeakInlines.h>
#include <cstddef>
#include <limits>
#include <memory>
#include <type_traits>
#include <utility>
#include <wtf/NeverDestroyed.h>

namespace Bun::Bindgen {

class EngineCallContext;

enum class NativeCellIdentity : uint8_t {
    FreshWrapper,
    PerRealmUnique,
    PerRealmShared,
};

enum class NativeMemoryAffinity : uint8_t {
    Any,
    VM,
};

// Generated traits derive from this and override the hooks their class declares.
struct NativeCellTraits {
    static constexpr NativeCellIdentity identity = NativeCellIdentity::FreshWrapper;
    static constexpr NativeMemoryAffinity memoryAffinity = NativeMemoryAffinity::Any;
    static constexpr std::nullptr_t nativeGeneration = nullptr;
    static constexpr std::nullptr_t upcast = nullptr;
    static constexpr std::nullptr_t memoryUsage = nullptr;
    static constexpr std::nullptr_t pendingActivity = nullptr;
    static constexpr std::nullptr_t wrapperCreated = nullptr;
    static constexpr std::nullptr_t initializeExternalNative = nullptr;
};

template<auto hook>
inline constexpr bool hasNativeHook = !std::is_null_pointer_v<decltype(hook)>;


// The realm whose registry generation keys wrappers created for a lexical global.
JSC::JSGlobalObject* wrapperRealm(JSC::JSGlobalObject*);

inline BindgenWrapperRegistry& ensureWrapperRegistry(JSC::VM& vm, WebCore::JSVMClientData* clientData)
{
    RELEASE_ASSERT(clientData);
    if (!clientData->bindgenWrapperRegistry)
        clientData->bindgenWrapperRegistry = std::make_unique<BindgenWrapperRegistry>(vm);
    return *clientData->bindgenWrapperRegistry;
}

// The wrapper owns exactly one reference to its most-derived native object.
// Levels below the root of a native class hierarchy only add typed views of it.
class NativeCellRoot : public JSC::JSDestructibleObject {
public:
    using Base = JSC::JSDestructibleObject;
    using NativeDestroy = void (*)(BindVirtualMachineHandle*, BindNativeHandle*);

    bool isDetached() const { return !m_ownerNative; }

    void* abortConstruction()
    {
        RELEASE_ASSERT(m_ownerNative);
        RELEASE_ASSERT(!m_nativeBorrowCount);
        unlinkWrapper();
        return takeNative();
    }

protected:
    NativeCellRoot(JSC::VM& vm, JSC::Structure* structure, void* ownerNative, NativeDestroy destroyNative, WebCore::JSVMClientData* clientData, NativeCellIdentityKey identity)
        : Base(vm, structure)
        , m_ownerNative(ownerNative)
        , m_destroyNative(destroyNative)
        , m_clientData(clientData)
        , m_identity(identity)
    {
    }

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm);
        auto& registry = ensureWrapperRegistry(vm, m_clientData);
        registry.add(&m_wrapperLink, this, detachNative);
        registerIdentity();
    }

    void initializeOwner(void* ownerNative, NativeDestroy destroyNative, WebCore::JSVMClientData* clientData, NativeCellIdentityKey identity)
    {
        RELEASE_ASSERT(ownerNative);
        RELEASE_ASSERT(destroyNative);
        RELEASE_ASSERT(!m_ownerNative);
        RELEASE_ASSERT(!m_destroyNative);
        RELEASE_ASSERT(m_clientData == clientData);
        m_ownerNative = ownerNative;
        m_destroyNative = destroyNative;
        m_identity = identity;
        registerIdentity();
    }

    void releaseNative()
    {
        if (void* native = takeNative())
            m_destroyNative(reinterpret_cast<BindVirtualMachineHandle*>(m_clientData->bunVM), reinterpret_cast<BindNativeHandle*>(native));
    }

    template<typename Cell>
    static void destroyCell(JSC::JSCell* cell)
    {
        auto* object = static_cast<Cell*>(cell);
        NativeCellRoot& root = *object;
        root.unlinkWrapper();
        root.releaseNative();
        object->~Cell();
    }

    void retainNativeBorrow()
    {
        RELEASE_ASSERT(m_nativeBorrowCount < std::numeric_limits<unsigned>::max());
        ++m_nativeBorrowCount;
    }

    void releaseNativeBorrow()
    {
        RELEASE_ASSERT(m_nativeBorrowCount);
        --m_nativeBorrowCount;
    }

    void* m_ownerNative;
    NativeDestroy m_destroyNative;
    WebCore::JSVMClientData* m_clientData;
    BindgenWrapperLink m_wrapperLink;
    NativeCellIdentityKey m_identity;
    unsigned m_nativeBorrowCount { 0 };

private:
    void* takeNative()
    {
        if (!m_ownerNative)
            return nullptr;
        RELEASE_ASSERT(!m_nativeBorrowCount);
        unregisterIdentity();
        return std::exchange(m_ownerNative, nullptr);
    }

    static void detachNative(void* wrapper)
    {
        static_cast<NativeCellRoot*>(wrapper)->releaseNative();
    }

    void unlinkWrapper()
    {
        RELEASE_ASSERT(m_clientData->bindgenWrapperRegistry);
        m_clientData->bindgenWrapperRegistry->remove(&m_wrapperLink);
        RELEASE_ASSERT(!m_wrapperLink.previous && !m_wrapperLink.next && !m_wrapperLink.wrapper && !m_wrapperLink.detach);
    }

    void registerIdentity()
    {
        if (!m_identity.realmGeneration)
            return;
        RELEASE_ASSERT(m_clientData->bindgenWrapperRegistry);
        m_clientData->bindgenWrapperRegistry->set(m_identity, this);
    }

    // Registry removal precedes releasing the native reference.
    void unregisterIdentity()
    {
        auto identity = std::exchange(m_identity, {});
        if (!identity.realmGeneration)
            return;
        RELEASE_ASSERT(m_clientData->bindgenWrapperRegistry);
        m_clientData->bindgenWrapperRegistry->remove(identity, this);
        RELEASE_ASSERT(m_clientData->bindgenWrapperRegistry->get(identity) != this);
    }
};

// Releases a transferred native reference unless the wrapper it was attached to commits.
class BindingNativeOwner final {
public:
    using Destroy = NativeCellRoot::NativeDestroy;

    BindingNativeOwner(BindVirtualMachineHandle* vm, BindNativeHandle* native, Destroy destroy)
        : m_vm(vm)
        , m_native(native)
        , m_destroy(destroy)
    {
        RELEASE_ASSERT(m_vm && m_native && m_destroy);
    }

    ~BindingNativeOwner()
    {
        if (!m_native)
            return;
        if (m_wrapper)
            RELEASE_ASSERT(m_wrapper->abortConstruction() == reinterpret_cast<void*>(m_native));
        m_destroy(m_vm, m_native);
    }

    BindingNativeOwner(const BindingNativeOwner&) = delete;
    BindingNativeOwner& operator=(const BindingNativeOwner&) = delete;

    void attachWrapper(NativeCellRoot* wrapper)
    {
        RELEASE_ASSERT(m_native && !m_wrapper);
        m_wrapper = wrapper;
    }

    void commit()
    {
        RELEASE_ASSERT(m_native && m_wrapper);
        m_native = nullptr;
    }

private:
    BindVirtualMachineHandle* m_vm;
    BindNativeHandle* m_native;
    Destroy m_destroy;
    NativeCellRoot* m_wrapper { nullptr };
};

template<typename Derived, typename Traits, typename Parent = NativeCellRoot>
class NativeCell : public Parent {
public:
    using Native = typename Traits::Native;
    using NativeDestroy = NativeCellRoot::NativeDestroy;

    static constexpr bool isRootLevel = std::is_same_v<Parent, NativeCellRoot>;
    static_assert(isRootLevel != hasNativeHook<Traits::upcast>, "exactly the levels below the root upcast to their parent");
    static_assert((Traits::identity == NativeCellIdentity::FreshWrapper) != hasNativeHook<Traits::nativeGeneration>, "registry identity requires a native generation");

    class NativeBorrow final {
        struct Release {
            Derived* owner;
            void operator()(Native*) const { owner->releaseNativeBorrow(); }
        };

    public:
        explicit NativeBorrow(Derived& owner)
            : m_native(owner.native(), Release { &owner })
        {
            RELEASE_ASSERT(m_native);
            owner.retainNativeBorrow();
        }
        NativeBorrow(const NativeBorrow&) = delete;
        NativeBorrow& operator=(const NativeBorrow&) = delete;
        NativeBorrow(NativeBorrow&&) noexcept = default;
        NativeBorrow& operator=(NativeBorrow&&) = delete;
        Native* get() const { return m_native.get(); }

    private:
        std::unique_ptr<Native, Release> m_native;
    };

    template<typename, JSC::SubspaceAccess mode>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<Derived, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return Traits::clientSubspace(spaces).get(); },
            [](auto& spaces, auto&& space) { Traits::clientSubspace(spaces) = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return Traits::subspace(spaces).get(); },
            [](auto& spaces, auto&& space) { Traits::subspace(spaces) = std::forward<decltype(space)>(space); });
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, global, prototype, JSC::TypeInfo(JSC::ObjectType, Derived::StructureFlags), Derived::info());
    }

    static Derived* create(JSC::VM& vm, JSC::Structure* structure, void* native, WebCore::JSVMClientData* clientData, NativeCellIdentityKey identity)
    {
        RELEASE_ASSERT(native);
        RELEASE_ASSERT(clientData);
        auto* object = new (NotNull, JSC::allocateCell<Derived>(vm)) Derived(vm, structure, native, native, Traits::destroyNative, clientData, identity);
        object->finishCreation(vm);
        return object;
    }

    // The native reference was just created, so no wrapper can own it yet.
    static Derived* createForNative(JSC::VM& vm, JSC::Structure* structure, void* native, WebCore::JSVMClientData* clientData, JSC::JSGlobalObject* realm)
    {
        auto identity = identityForNewWrapper(clientData, realm, native);
        return create(vm, structure, native, clientData, identity);
    }

    template<typename StructureFor>
    static BindStatus wrapNative(BindGlobalObjectHandle* globalHandle, BindNativeHandle* nativeHandle, BindEncodedJSValue* outValue, StructureFor structureFor)
    {
        RELEASE_ASSERT(globalHandle);
        RELEASE_ASSERT(nativeHandle);
        RELEASE_ASSERT(outValue);
        auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
        return invokeBindingStatusEntry(global, [&]() -> BindStatus {
            auto& vm = JSC::getVM(global);
            auto throwScope = DECLARE_THROW_SCOPE(vm);
            auto* clientData = WebCore::clientData(vm);
            auto* native = reinterpret_cast<void*>(nativeHandle);
            BindingNativeOwner nativeOwner(reinterpret_cast<BindVirtualMachineHandle*>(clientData->bunVM), nativeHandle, Traits::releaseNativeOnVM);
            *outValue = 0;
            if (materializeBindingException(throwScope))
                return BIND_STATUS_PENDING_EXCEPTION;
            NativeCellIdentityKey identity;
            if constexpr (Traits::identity == NativeCellIdentity::PerRealmShared) {
                auto& registry = ensureWrapperRegistry(vm, clientData);
                identity = { registry.ensureRealm(wrapperRealm(global)), Traits::nativeGeneration(nativeHandle) };
                if (auto* cached = registry.get(identity)) {
                    auto* wrapper = dynamicDowncast<Derived>(cached);
                    RELEASE_ASSERT(wrapper);
                    RELEASE_ASSERT(wrapper->native() == native);
                    if (materializeBindingException(throwScope))
                        return BIND_STATUS_PENDING_EXCEPTION;
                    *outValue = encodeBindingValue(wrapper);
                    return BIND_STATUS_OK;
                }
            } else if constexpr (Traits::identity == NativeCellIdentity::PerRealmUnique)
                identity = identityForNewWrapper(clientData, wrapperRealm(global), native);
            auto* structure = structureFor(global);
            if (materializeBindingException(throwScope))
                return BIND_STATUS_PENDING_EXCEPTION;
            auto* wrapper = create(vm, structure, native, clientData, identity);
            nativeOwner.attachWrapper(wrapper);
            if (materializeBindingException(throwScope))
                return BIND_STATUS_PENDING_EXCEPTION;
            nativeOwner.commit();
            wrapper->reportNativeMemoryAllocated(vm);
            if (materializeBindingException(throwScope))
                return BIND_STATUS_PENDING_EXCEPTION;
            *outValue = encodeBindingValue(wrapper);
            return BIND_STATUS_OK;
        });
    }

    static void destroy(JSC::JSCell* cell)
    {
        NativeCellRoot::destroyCell<Derived>(cell);
    }

    static size_t estimatedSize(JSC::JSCell* cell, JSC::VM& vm)
    {
        size_t size = Parent::estimatedSize(cell, vm);
        if constexpr (hasNativeHook<Traits::memoryUsage>)
            size += uncheckedDowncast<Derived>(cell)->ownNativeMemorySize(vm);
        return size;
    }

    Native* native() const { return this->isDetached() ? nullptr : static_cast<Native*>(m_native); }

    void adoptExternalNative(JSC::JSGlobalObject* global, void* native)
        requires hasNativeHook<Traits::initializeExternalNative>
    {
        RELEASE_ASSERT(global);
        RELEASE_ASSERT(native);
        auto& vm = JSC::getVM(global);
        auto throwScope = DECLARE_THROW_SCOPE(vm);
        auto* clientData = WebCore::clientData(vm);
        auto* nativeHandle = reinterpret_cast<BindNativeHandle*>(native);
        auto status = Traits::initializeExternalNative(reinterpret_cast<BindGlobalObjectHandle*>(global), nativeHandle);
        RELEASE_ASSERT(status == BIND_STATUS_OK || status == BIND_STATUS_PENDING_EXCEPTION || status == BIND_STATUS_OUT_OF_MEMORY);
        if (status != BIND_STATUS_OK) {
            if (!bindingExceptionAfterDispatch(throwScope, status))
                throwBindingOutOfMemoryError(global, throwScope);
            return;
        }
        BindingNativeOwner nativeOwner(reinterpret_cast<BindVirtualMachineHandle*>(clientData->bunVM), nativeHandle, Traits::releaseNativeOnVM);
        if (bindingExceptionAfterDispatch(throwScope, status))
            return;
        NativeCellIdentityKey identity;
        if constexpr (Traits::identity != NativeCellIdentity::FreshWrapper)
            identity = identityForNewWrapper(clientData, wrapperRealm(global), native);
        initializeNative(native, native, Traits::destroyNative, clientData, identity);
        nativeOwner.attachWrapper(this);
        if (materializeBindingException(throwScope))
            return;
        nativeOwner.commit();
        reportNativeMemoryAllocated(vm);
        materializeBindingException(throwScope);
    }

    void adoptConstructionFrom(Derived& source)
    {
        RELEASE_ASSERT(source.m_native);
        RELEASE_ASSERT(source.m_ownerNative);
        RELEASE_ASSERT(source.m_destroyNative);
        RELEASE_ASSERT(source.m_clientData == this->m_clientData);
        auto* native = source.m_native;
        auto destroyNative = source.m_destroyNative;
        auto identity = source.m_identity;
        auto* ownerNative = source.abortConstruction();
        auto& vm = JSC::getVM(this->globalObject());
        auto throwScope = DECLARE_THROW_SCOPE(vm);
        BindingNativeOwner nativeOwner(reinterpret_cast<BindVirtualMachineHandle*>(this->m_clientData->bunVM), reinterpret_cast<BindNativeHandle*>(ownerNative), destroyNative);
        static_cast<Derived*>(this)->moveInstanceSlotsFrom(source, vm);
        initializeNative(native, ownerNative, destroyNative, this->m_clientData, identity);
        nativeOwner.attachWrapper(this);
        if (materializeBindingException(throwScope))
            return;
        nativeOwner.commit();
    }

    void reportNativeMemoryAllocated(JSC::VM& vm)
    {
        vm.heap.reportExtraMemoryAllocated(this, nativeMemorySize(vm));
    }

protected:
    NativeCell(JSC::VM& vm, JSC::Structure* structure, void* native, void* ownerNative, NativeDestroy destroyNative, WebCore::JSVMClientData* clientData, NativeCellIdentityKey identity)
        requires isRootLevel
        : Parent(vm, structure, ownerNative, destroyNative, clientData, identity)
        , m_native(native)
    {
    }

    NativeCell(JSC::VM& vm, JSC::Structure* structure, void* native, void* ownerNative, NativeDestroy destroyNative, WebCore::JSVMClientData* clientData, NativeCellIdentityKey identity)
        requires(!isRootLevel)
        : Parent(vm, structure, native ? upcast(native) : nullptr, ownerNative, destroyNative, clientData, identity)
        , m_native(native)
    {
    }

    void finishCreation(JSC::VM& vm)
    {
        Parent::finishCreation(vm);
        if constexpr (hasNativeHook<Traits::pendingActivity>)
            m_pendingActivityWeakThis = JSC::Weak<JSC::JSObject>(this, pendingActivityOwner());
        notifyWrapperCreated();
        ASSERT(this->inherits(Derived::info()));
    }

    void initializeNative(void* native, void* ownerNative, NativeDestroy destroyNative, WebCore::JSVMClientData* clientData, NativeCellIdentityKey identity)
    {
        RELEASE_ASSERT(native);
        RELEASE_ASSERT(!m_native);
        if constexpr (isRootLevel)
            this->initializeOwner(ownerNative, destroyNative, clientData, identity);
        else
            Parent::initializeNative(upcast(native), ownerNative, destroyNative, clientData, identity);
        m_native = native;
        notifyWrapperCreated();
    }

    size_t nativeMemorySize(JSC::VM& vm) const
    {
        size_t size = 0;
        if constexpr (!isRootLevel)
            size += Parent::nativeMemorySize(vm);
        if constexpr (hasNativeHook<Traits::memoryUsage>)
            size += ownNativeMemorySize(vm);
        return size;
    }

    template<typename Visitor>
    void visitNativeMemory(Visitor& visitor)
    {
        static_assert(Traits::memoryAffinity == NativeMemoryAffinity::Any, "only any-thread native memory is reported while visiting");
        if (auto* native = this->native())
            visitor.reportExtraMemoryVisited(Traits::memoryUsage(reinterpret_cast<BindNativeHandle*>(native)));
    }

    size_t ownNativeMemorySize(JSC::VM& vm) const
    {
        auto* native = this->native();
        if (!native)
            return 0;
        if constexpr (Traits::memoryAffinity == NativeMemoryAffinity::VM)
            return Traits::memoryUsage(reinterpret_cast<BindVirtualMachineHandle*>(WebCore::clientData(vm)->bunVM), reinterpret_cast<BindNativeHandle*>(native));
        else
            return Traits::memoryUsage(reinterpret_cast<BindNativeHandle*>(native));
    }

    void* m_native;

private:
    friend class EngineCallContext;

    struct NoPendingActivity { };

    class PendingActivityOwner final : public JSC::WeakHandleOwner {
    public:
        bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, JSC::AbstractSlotVisitor&, ASCIILiteral* reason) final
        {
            auto* object = uncheckedDowncast<Derived>(handle.slot()->asCell());
            auto* native = object->native();
            if (!native || !Traits::pendingActivity(reinterpret_cast<BindNativeHandle*>(native)))
                return false;
            if (reason) [[unlikely]]
                *reason = "has pending activity"_s;
            return true;
        }
        void finalize(JSC::Handle<JSC::Unknown>, void*) final { }
    };

    static JSC::WeakHandleOwner* pendingActivityOwner()
    {
        static NeverDestroyed<PendingActivityOwner> owner;
        return &owner.get();
    }

    static void* upcast(void* native)
    {
        return reinterpret_cast<void*>(Traits::upcast(reinterpret_cast<BindNativeHandle*>(native)));
    }

    static NativeCellIdentityKey identityForNewWrapper(WebCore::JSVMClientData* clientData, JSC::JSGlobalObject* realm, void* native)
    {
        if constexpr (Traits::identity == NativeCellIdentity::FreshWrapper) {
            UNUSED_PARAM(clientData);
            UNUSED_PARAM(realm);
            UNUSED_PARAM(native);
            return { };
        } else {
            auto& registry = ensureWrapperRegistry(realm->vm(), clientData);
            NativeCellIdentityKey identity { registry.ensureRealm(realm), Traits::nativeGeneration(reinterpret_cast<BindNativeHandle*>(native)) };
            RELEASE_ASSERT(!registry.get(identity));
            return identity;
        }
    }

    BindingNativeBorrow bindingBorrowNative()
    {
        auto* borrowed = native();
        RELEASE_ASSERT(borrowed);
        this->retainNativeBorrow();
        return { this, borrowed, [](void* owner) {
            static_cast<NativeCell*>(owner)->releaseNativeBorrow();
        } };
    }

    void notifyWrapperCreated()
    {
        if constexpr (hasNativeHook<Traits::wrapperCreated>) {
            if (!m_native)
                return;
            auto* global = this->globalObject();
            JSC::JSValue wrapperValue = this;
            BindClassRefView wrapper {
                .native = reinterpret_cast<const BindNativeHandle*>(m_native),
                .wrapper = bindingValueHandle(wrapperValue),
            };
            BindCallContext context {
                .global_object = reinterpret_cast<BindGlobalObjectHandle*>(global),
                .promise = nullptr,
                .native_receiver = reinterpret_cast<BindNativeHandle*>(m_native),
                .caller_frame = nullptr,
                .deferred_conversions = nullptr,
                .call_id = takeBindingCallId(),
            };
            finishBindingVoidCall(global, Traits::wrapperCreated(&context, &wrapper));
        }
    }

    [[no_unique_address]] std::conditional_t<hasNativeHook<Traits::pendingActivity>, JSC::Weak<JSC::JSObject>, NoPendingActivity> m_pendingActivityWeakThis;
};

}
