#include "root.h"

#include "BunClientData.h"
#include "BunDebugger.h"
#include "sqlite/JSSQLStatement.h"
#include "SchemaBindings.h"
#include "../../runtime/webview/ChromeBackend.h"
#include "../../runtime/webview/WebKitBackend.h"
#include "WebCoreJSBuiltins.h"
#include "ZigGlobalObject.h"

#include "DOMClientIsoSubspaces.h"
#include "DOMIsoSubspaces.h"
#include <JavaScriptCore/FastMallocAlignedMemoryAllocator.h>
#include <JavaScriptCore/HeapInlines.h>
#include <JavaScriptCore/IsoHeapCellType.h>
#include <JavaScriptCore/JSDestructibleObjectHeapCellType.h>
#include <JavaScriptCore/SubspaceInlines.h>
#include <JavaScriptCore/VM.h>
#include <wtf/MainThread.h>


#include "BunGCOutputConstraint.h"
#include "WebCoreTypedArrayController.h"
#include <JavaScriptCore/JSCInlines.h>

#include "JSDOMWrapper.h"
#include <JavaScriptCore/DeferredWorkTimer.h>
#include "NodeVM.h"
#include "../../bake/BakeGlobalObject.h"
#include "napi_handle_scope.h"

namespace WebCore {
using namespace JSC;

RefPtr<JSC::SourceProvider> createBuiltinsSourceProvider();

JSHeapData::JSHeapData(Heap& heap)
    : m_heapCellTypeForJSWorkerGlobalScope(JSC::IsoHeapCellType::Args<Zig::GlobalObject>())
    , m_heapCellTypeForNodeVMGlobalObject(JSC::IsoHeapCellType::Args<Bun::NodeVMGlobalObject>())
    , m_heapCellTypeForBakeGlobalObject(JSC::IsoHeapCellType::Args<Bake::GlobalObject>())
    , m_heapCellTypeForNapiHandleScopeImpl(JSC::IsoHeapCellType::Args<Bun::NapiHandleScopeImpl>())
    , m_domNamespaceObjectSpace ISO_SUBSPACE_INIT(heap, heap.cellHeapCellType, JSDOMObject)
    , m_subspaces(makeUnique<DOMIsoSubspaces>())

{
}

JSHeapData::~JSHeapData() = default;

#define CLIENT_ISO_SUBSPACE_INIT(subspace) subspace(m_heapData->subspace)

JSVMClientData::JSVMClientData(VM& vm, RefPtr<JSC::SourceProvider> sourceProvider)
    : m_vm(vm)
    , m_builtinNames(vm)
    , m_builtinFunctions(makeUnique<JSBuiltinFunctions>(vm, sourceProvider))
    , m_bindgenIdentifiers(std::make_unique<Bun::Bindgen::IdentifierTable>(vm))
    , m_heapData(JSHeapData::ensureHeapData(vm.heap))
    , CLIENT_ISO_SUBSPACE_INIT(m_domNamespaceObjectSpace)
    , m_clientSubspaces(makeUnique<DOMClientIsoSubspaces>())
{
}

#undef CLIENT_ISO_SUBSPACE_INIT

JSHeapData* JSHeapData::ensureHeapData(Heap& heap)
{
    if (!Options::useGlobalGC())
        return new JSHeapData(heap);

    static JSHeapData* singleton = nullptr;
    static std::once_flag onceFlag;
    std::call_once(onceFlag, [&] {
        singleton = new JSHeapData(heap);
    });
    return singleton;
}

DEFINE_ALLOCATOR_WITH_HEAP_IDENTIFIER(JSVMClientData);

JSVMClientData::~JSVMClientData()
{
    if (webViewChromeTransport)
        webViewChromeTransport->shutdown();
#if OS(DARWIN)
    if (webViewHostClient)
        webViewHostClient->shutdown();
#endif
    Bun::clearDebuggerCallbacksForVM(*this);
    closeSQLiteDatabasesForVM(*this);
    if (bindgenWrapperRegistry)
        bindgenWrapperRegistry->detachAll();
    isolationSourceProviderCache.clear();
    Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineDrainNativeFinalizers(
        reinterpret_cast<VirtualMachine*>(bunVM));
    m_clients.forEach([](auto& client) {
        client.willDestroyVM();
    });
    m_clients.clear();

    if (bindgenWrapperRegistry)
        bindgenWrapperRegistry->detachAll();
    Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineDrainNativeFinalizers(
        reinterpret_cast<VirtualMachine*>(bunVM));
    RELEASE_ASSERT(m_vm.heap.isShuttingDown());
    // VM deletes client data only after lastChanceToFinalize has completed.
    Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineCloseNativeFinalizers(
        reinterpret_cast<VirtualMachine*>(bunVM));
}

void JSVMClientData::create(VM* vm, VirtualMachine* bunVM)
{
    auto provider = WebCore::createBuiltinsSourceProvider();
    JSVMClientData* clientData = new JSVMClientData(*vm, provider);
    clientData->bunVM = bunVM;
    clientData->webViewChromeTransport = makeUnique<Bun::CDP::Transport>(bunVM);
#if OS(DARWIN)
    clientData->webViewHostClient = makeUnique<Bun::WK::HostClient>(bunVM);
#endif
    vm->deferredWorkTimer->onAddPendingWork = [clientData](Ref<JSC::DeferredWorkTimer::Ticket>&& ticket, JSC::DeferredWorkTimer::WorkType kind) -> void {
        Bun::JSCTaskScheduler::onAddPendingWork(clientData, WTF::move(ticket), kind);
    };
    vm->deferredWorkTimer->onScheduleWorkSoon = [clientData, vm](Ref<JSC::DeferredWorkTimer::Ticket>&& ticket, JSC::DeferredWorkTimer::Task&& task) -> void {
        Bun::JSCTaskScheduler::onScheduleWorkSoon(*vm, clientData, WTF::move(ticket), WTF::move(task));
    };
    vm->deferredWorkTimer->onCancelPendingWork = [clientData](JSC::DeferredWorkTimer::Ticket& ticket) -> void {
        Bun::JSCTaskScheduler::onCancelPendingWork(clientData, ticket);
    };

    vm->clientData = clientData; // ~VM deletes this pointer.

    vm->heap.addMarkingConstraint(makeUnique<WebCore::DOMGCOutputConstraint>(*vm, clientData->heapData()));
    vm->m_typedArrayController = adoptRef(new WebCoreTypedArrayController(true));
}

WebCore::HTTPHeaderIdentifiers& JSVMClientData::httpHeaderIdentifiers()
{
    if (!m_httpHeaderIdentifiers)
        m_httpHeaderIdentifiers.emplace();
    return *m_httpHeaderIdentifiers;
}

} // namespace WebCore
