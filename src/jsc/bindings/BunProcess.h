#pragma once

#include "root.h"

#include "BunBuiltinNames.h"
#include "BunClientData.h"
#include "JSEventEmitter.h"
#include "JSNextTickQueue.h"
#include <cstdint>
#include <optional>
#include <span>

namespace Zig {
class GlobalObject;
}

namespace Bun {
using namespace JSC;

class Process : public WebCore::JSEventEmitter {
    using Base = WebCore::JSEventEmitter;

    LazyProperty<Process, JSObject> m_bindingUV;
    LazyProperty<Process, JSObject> m_bindingNatives;
    // Function that looks up "emit" on "process" and calls it with the provided arguments
    // Only used by internal code via passing to queueNextTick
    LazyProperty<Process, JSFunction> m_emitHelperFunction;
    WriteBarrier<Unknown> m_uncaughtExceptionCaptureCallback;
    WriteBarrier<JSObject> m_nextTickFunction;
    // https://github.com/nodejs/node/blob/2eff28fb7a93d3f672f80b582f664a7c701569fb/lib/internal/bootstrap/switches/does_own_process_state.js#L113-L116
    WriteBarrier<JSString> m_cachedCwd;

public:
    Process(JSC::Structure* structure, WebCore::JSDOMGlobalObject& globalObject, Ref<WebCore::EventEmitter>&& impl)
        : Base(structure, globalObject, WTF::move(impl))
    {
    }

    DECLARE_EXPORT_INFO;
    bool m_reportOnUncaughtException = false;

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<Process*>(cell)->Process::~Process();
    }

    ~Process();

    bool m_isExitCodeObservable = false;
    bool m_sourceMapsEnabled = false;

    static constexpr unsigned StructureFlags = Base::StructureFlags | HasStaticPropertyTable;

    JSValue constructNextTickFn(JSC::VM& vm, Zig::GlobalObject* globalObject);
    void queueNextTick(JSC::JSGlobalObject* globalObject, JSValue, JSValue);
    void queueNextTick(JSC::JSGlobalObject*, JSValue callback, std::span<const JSValue> arguments);
    std::optional<JSNextTickQueue::PreparedTask> prepareNextTick(Zig::GlobalObject*, JSValue callback, std::span<const JSValue> arguments);
    std::optional<JSNextTickQueue::PreparedTask> prepareNextTick(Zig::GlobalObject*, JSValue callback, const ArgList& arguments, JSValue receiver = jsUndefined());

    std::optional<JSNextTickQueue::PreparedTask> prepareEmitOnNextTick(Zig::GlobalObject*, ASCIILiteral eventName, JSValue event);

    static void emitWarningErrorInstance(JSC::JSGlobalObject*, JSC::ErrorInstance*);
    static void emitWarning(JSC::JSGlobalObject*, const WTF::String& message, const WTF::String& name, const std::optional<WTF::String>& code = std::nullopt);
    static bool noDeprecation();
    static void setNoDeprecation(bool);
    static bool throwDeprecation();
    static void setThrowDeprecation(bool);

    JSString* cachedCwd() { return m_cachedCwd.get(); }
    void setCachedCwd(JSC::VM& vm, JSString* cwd) { m_cachedCwd.set(vm, this, cwd); }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject,
        JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype,
            JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static Process* create(WebCore::JSDOMGlobalObject& globalObject, JSC::Structure* structure)
    {
        auto emitter = WebCore::EventEmitter::create(*globalObject.scriptExecutionContext());
        Process* accessor = new (NotNull, JSC::allocateCell<Process>(globalObject.vm())) Process(structure, globalObject, WTF::move(emitter));
        accessor->finishCreation(globalObject.vm());
        return accessor;
    }

    DECLARE_VISIT_CHILDREN;

    template<typename, SubspaceAccess mode>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<Process, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForProcessObject.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForProcessObject = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForProcessObject.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForProcessObject = std::forward<decltype(space)>(space); });
    }

    void finishCreation(JSC::VM& vm);

    inline void setUncaughtExceptionCaptureCallback(JSC::JSValue callback)
    {
        m_uncaughtExceptionCaptureCallback.set(vm(), this, callback);
    }

    inline JSC::JSValue getUncaughtExceptionCaptureCallback()
    {
        return m_uncaughtExceptionCaptureCallback.get();
    }

    inline JSObject* bindingUV() { return m_bindingUV.getInitializedOnMainThread(this); }
    inline JSObject* bindingNatives() { return m_bindingNatives.getInitializedOnMainThread(this); }
};

bool isSignalName(WTF::String input);
std::optional<uint8_t> signalNumberForName(WTF::StringView name);

} // namespace Bun
