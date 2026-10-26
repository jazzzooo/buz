#pragma once

struct VirtualMachine;

namespace WebCore {

class DOMClientIsoSubspaces;
class DOMIsoSubspaces;
class JSBuiltinFunctions;
class SQLiteDatabaseData;

class DOMWrapperWorld;
}

namespace Bun {
class BindgenWrapperRegistry;
struct DebuggerCallback;
struct InspectorTarget;
namespace CDP { class Transport; }
namespace WK { struct HostClient; }
namespace Bindgen {
class IdentifierTable;
}
}

#include "root.h"

#include "DOMClientIsoSubspaces.h"
#include "DOMIsoSubspaces.h"
#include "BunBuiltinNames.h"
#include <wtf/Function.h>
#include <wtf/HashSet.h>
#include <wtf/Vector.h>
#include <wtf/HashMap.h>
#include <wtf/WeakHashSet.h>
#include <wtf/RefPtr.h>
#include "JSVMClientDataClient.h"
#include <JavaScriptCore/WeakInlines.h>
#include <wtf/StdLibExtras.h>
#include "JSCTaskScheduler.h"
#include "HTTPHeaderIdentifiers.h"
namespace Zig {
class GlobalObject;
}

namespace WebCore {
using namespace JSC;
using namespace Zig;

enum class UseCustomHeapCellType { Yes,
    No };

class JSHeapData {
    WTF_MAKE_NONCOPYABLE(JSHeapData);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(JSHeapData);
    friend class JSVMClientData;

public:
    JSHeapData(JSC::Heap&);
    ~JSHeapData();

    static JSHeapData* ensureHeapData(JSC::Heap&);

    Lock& lock() { return m_lock; }
    DOMIsoSubspaces& subspaces() { return *m_subspaces.get(); }

    Vector<JSC::IsoSubspace*>& outputConstraintSpaces() { return m_outputConstraintSpaces; }

    template<typename Func>
    void forEachOutputConstraintSpace(const Func& func)
    {
        for (auto* space : m_outputConstraintSpaces)
            func(*space);
    }

    JSC::IsoHeapCellType m_heapCellTypeForJSWorkerGlobalScope;
    JSC::IsoHeapCellType m_heapCellTypeForNodeVMGlobalObject;
    JSC::IsoHeapCellType m_heapCellTypeForNapiHandleScopeImpl;
    JSC::IsoHeapCellType m_heapCellTypeForBakeGlobalObject;
    // JSC::IsoHeapCellType m_heapCellTypeForGeneratedClass;

private:
    Lock m_lock;

private:
    std::unique_ptr<DOMIsoSubspaces> m_subspaces;
    JSC::IsoSubspace m_domNamespaceObjectSpace;

    Vector<JSC::IsoSubspace*> m_outputConstraintSpaces;
};

DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(JSVMClientData);

class JSVMClientData : public JSC::VM::ClientData {
    WTF_MAKE_NONCOPYABLE(JSVMClientData);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED_WITH_HEAP_IDENTIFIER(JSVMClientData, JSVMClientData);

public:
    explicit JSVMClientData(JSC::VM&, RefPtr<JSC::SourceProvider>);

    virtual ~JSVMClientData();

    static void create(JSC::VM*, VirtualMachine*);

    JSHeapData& heapData() { return *m_heapData; }
    BunBuiltinNames& builtinNames() { return m_builtinNames; }
    JSBuiltinFunctions& builtinFunctions() { return *m_builtinFunctions; }

    String overrideSourceURL(const StackFrame&, const String& originalSourceURL) const
    {
        return originalSourceURL;
    }

    DOMWrapperWorld* wrapperWorlds() const { return m_wrapperWorlds; }
    void rememberWorld(DOMWrapperWorld&);
    void forgetWorld(DOMWrapperWorld&);


    DOMClientIsoSubspaces& clientSubspaces() { return *m_clientSubspaces.get(); }

    Vector<JSC::IsoSubspace*>& outputConstraintSpaces() { return m_outputConstraintSpaces; }

    WebCore::HTTPHeaderIdentifiers& httpHeaderIdentifiers();
    Bun::Bindgen::IdentifierTable& bindgenIdentifiers() { return *m_bindgenIdentifiers; }

    template<typename Func> void forEachOutputConstraintSpace(const Func& func)
    {
        for (auto* space : m_outputConstraintSpaces)
            func(*space);
    }

    VirtualMachine* bunVM;
    Bun::JSCTaskScheduler deferredWorkTimer;
    std::unique_ptr<Bun::BindgenWrapperRegistry> bindgenWrapperRegistry;
    std::unique_ptr<Bun::CDP::Transport> webViewChromeTransport;
#if OS(DARWIN)
    std::unique_ptr<Bun::WK::HostClient> webViewHostClient;
#endif
    SQLiteDatabaseData* sqliteDatabaseHead { nullptr };
    bool sqliteClosing { false };
    Bun::DebuggerCallback* debuggerCallbacksHead { nullptr };
    Bun::InspectorTarget* inspectorTargetsHead { nullptr };

    // Backing storage for Bun::IsolatedModuleCache (see IsolatedModuleCache.h).
    // All access should go through that class. Stored as the JSC base type to
    // avoid pulling ZigSourceProvider.h into this header; the cache class
    // downcasts on lookup. Values hold strong refs by design: this map is the
    // only owner once the previous global is GC'd, so a weak map would empty
    // after every swap.
    WTF::UncheckedKeyHashMap<WTF::String, RefPtr<JSC::SourceProvider>> isolationSourceProviderCache;

    void addClient(JSVMClientDataClient& client) { m_clients.add(client); }

private:
    bool isWebCoreJSClientData() const final { return true; }

    JSC::VM& m_vm;
    BunBuiltinNames m_builtinNames;
    std::unique_ptr<JSBuiltinFunctions> m_builtinFunctions;
    std::unique_ptr<Bun::Bindgen::IdentifierTable> m_bindgenIdentifiers;

    JSHeapData* m_heapData;

    DOMWrapperWorld* m_wrapperWorlds { nullptr };
    friend class DOMWrapperWorld;
    uint64_t wrapperIdentity(void* native) const;
    uint64_t retainWrapperIdentity(void* native);
    void releaseWrapperIdentity(void* native, uint64_t generation);
    struct WrapperIdentity {
        uint64_t generation;
        size_t registrations;
    };
    HashMap<void*, WrapperIdentity> m_wrapperIdentities;
    uint64_t m_nextWrapperIdentity { 1 };
    JSC::GCClient::IsoSubspace m_domNamespaceObjectSpace;

    std::unique_ptr<DOMClientIsoSubspaces> m_clientSubspaces;
    Vector<JSC::IsoSubspace*> m_outputConstraintSpaces;

    std::optional<WebCore::HTTPHeaderIdentifiers> m_httpHeaderIdentifiers;
    WeakHashSet<JSVMClientDataClient> m_clients;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::JSVMClientData)
static bool isType(const JSC::VM::ClientData& clientData) { return clientData.isWebCoreJSClientData(); }
SPECIALIZE_TYPE_TRAITS_END()

namespace WebCore {

template<typename T, UseCustomHeapCellType useCustomHeapCellType, typename GetClient, typename SetClient, typename GetServer, typename SetServer>
ALWAYS_INLINE JSC::GCClient::IsoSubspace* subspaceForImpl(JSC::VM& vm, GetClient getClient, SetClient setClient, GetServer getServer, SetServer setServer, JSC::HeapCellType& (*getCustomHeapCellType)(JSHeapData&) = nullptr)
{
    auto& clientData = *downcast<JSVMClientData>(vm.clientData);
    auto& clientSubspaces = clientData.clientSubspaces();
    if (auto* clientSpace = getClient(clientSubspaces))
        return clientSpace;

    auto& heapData = clientData.heapData();
    Locker locker { heapData.lock() };

    auto& subspaces = heapData.subspaces();
    JSC::IsoSubspace* space = getServer(subspaces);
    if (!space) {
        JSC::Heap& heap = vm.heap;
        std::unique_ptr<JSC::IsoSubspace> uniqueSubspace;
        static_assert(useCustomHeapCellType == UseCustomHeapCellType::Yes || std::is_base_of_v<JSC::JSDestructibleObject, T> || T::needsDestruction == JSC::DoesNotNeedDestruction);
        if constexpr (useCustomHeapCellType == UseCustomHeapCellType::Yes)
            uniqueSubspace = makeUnique<JSC::IsoSubspace> ISO_SUBSPACE_INIT(heap, getCustomHeapCellType(heapData), T);
        else {
            if constexpr (std::is_base_of_v<JSC::JSDestructibleObject, T>)
                uniqueSubspace = makeUnique<JSC::IsoSubspace> ISO_SUBSPACE_INIT(heap, heap.destructibleObjectHeapCellType, T);
            else
                uniqueSubspace = makeUnique<JSC::IsoSubspace> ISO_SUBSPACE_INIT(heap, heap.cellHeapCellType, T);
        }
        space = uniqueSubspace.get();
        setServer(subspaces, WTF::move(uniqueSubspace));

        IGNORE_WARNINGS_BEGIN("unreachable-code")
        IGNORE_WARNINGS_BEGIN("tautological-compare")
        void (*myVisitOutputConstraint)(JSC::JSCell*, JSC::SlotVisitor&) = T::visitOutputConstraints;
        void (*jsCellVisitOutputConstraint)(JSC::JSCell*, JSC::SlotVisitor&) = JSC::JSCell::visitOutputConstraints;
        if (myVisitOutputConstraint != jsCellVisitOutputConstraint)
            heapData.outputConstraintSpaces().append(space);
        IGNORE_WARNINGS_END
        IGNORE_WARNINGS_END
    }

    auto uniqueClientSubspace = makeUnique<JSC::GCClient::IsoSubspace>(*space);
    auto* clientSpace = uniqueClientSubspace.get();
    setClient(clientSubspaces, WTF::move(uniqueClientSubspace));
    return clientSpace;
}

static JSVMClientData* clientData(JSC::VM& vm)
{
    return downcast<JSVMClientData>(vm.clientData);
}

static inline BunBuiltinNames& builtinNames(JSC::VM& vm)
{
    return clientData(vm)->builtinNames();
}

} // namespace WebCore

inline VirtualMachine* bunVM(JSC::VM& vm)
{
    return WebCore::clientData(vm)->bunVM;
}

namespace WebCore {
using JSVMClientData = WebCore::JSVMClientData;
using JSHeapData = WebCore::JSHeapData;

}
