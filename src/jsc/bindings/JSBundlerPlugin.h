#pragma once

#include "bun-native-bundler-plugin-api/bundler_plugin.h"
#include "BunClientData.h"
#include "root.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/LazyProperty.h>
#include <JavaScriptCore/RegularExpression.h>
#include "napi_external.h"
#include <JavaScriptCore/Yarr.h>

typedef void (*JSBundlerPluginNativeOnBeforeParseCallback)(const OnBeforeParseArguments*, OnBeforeParseResult*);

namespace Bun {

using namespace JSC;
using BunPluginTarget = Bindgen::BunPluginTarget;

class BundlerPlugin final {
public:
    /// In native plugins, the regular expression could be called concurrently on multiple threads.
    /// Therefore, we need a mutex to synchronize access.
    class FilterRegExp {
    public:
        String m_pattern;
        Yarr::RegularExpression regex;
        WTF::Lock lock {};

        FilterRegExp(FilterRegExp&& other)
            : m_pattern(WTF::move(other.m_pattern))
            , regex(WTF::move(other.regex))
        {
        }

        FilterRegExp(const String& pattern, OptionSet<Yarr::Flags> flags)
            // Ensure it's safe for cross-thread usage.
            : m_pattern(pattern.isolatedCopy())
            , regex(m_pattern, flags)
        {
        }

        bool match(JSC::VM& vm, const String& path);
    };

    template<typename Entry> class NamespaceList {
    public:
        Vector<Entry>* group(const String& namespaceStr)
        {
            if (namespaceStr.isEmpty())
                return &fileNamespace;

            for (auto& entry : namespaces) {
                if (entry.name == namespaceStr)
                    return &entry.entries;
            }

            return nullptr;
        }

        bool tryAppend(const String& namespaceString, Entry&& entry)
        {
            if (auto* entries = group(namespaceString))
                return entries->tryAppend(WTF::move(entry));

            NamespaceGroup newGroup { namespaceString, {} };
            if (!newGroup.entries.tryAppend(WTF::move(entry)))
                return false;
            return namespaces.tryAppend(WTF::move(newGroup));
        }

        bool isEmpty() const { return fileNamespace.isEmpty() && namespaces.isEmpty(); }

    private:
        struct NamespaceGroup {
            String name;
            Vector<Entry> entries;
        };

        Vector<Entry> fileNamespace;
        Vector<NamespaceGroup> namespaces;
    };

    using FilterList = NamespaceList<FilterRegExp>;

    struct NativePluginCallback {
        JSBundlerPluginNativeOnBeforeParseCallback callback;
        void* external;
        // BUN_PLUGIN_NAME belongs to the loaded module, whose handle remains open.
        const char* name;
    };

    struct NativePluginEntry {
        FilterRegExp filter;
        NativePluginCallback callback;
    };

    class NativePluginList : public NamespaceList<NativePluginEntry> {
    public:
        Bindgen::NativeAllocationResult<uint32_t> call(JSC::VM& vm, JSBundlerPluginParseContext* bunContext, const String& namespaceString, const String& path, OnBeforeParseArguments* onBeforeParseArgs, OnBeforeParseResult* onBeforeParseResult);
    };

public:
    bool anyMatchesCrossThread(JSC::VM&, const String& namespaceString, const String& path, bool isOnLoad);
    void tombstone() { tombstoned = true; }

    BundlerPlugin(JSC::VM& vm, BunPluginTarget target)
        : m_vm(&vm)
    {
        this->target = target;
    }

    JSC::VM& vm() const { return *m_vm; }

    FilterList onLoad = {};
    FilterList onResolve = {};
    NativePluginList onBeforeParse = {};
    BunPluginTarget target { BunPluginTarget::browser };

    bool tombstoned { false };

private:
    JSC::VM* m_vm;
};

class JSBundlerPlugin final : public JSC::JSDestructibleObject {
public:
    using Base = JSC::JSDestructibleObject;
    static JSBundlerPlugin* create(JSC::VM& vm,
        JSC::Structure* structure,
        BunPluginTarget target)
    {
        JSBundlerPlugin* ptr = new (NotNull, JSC::allocateCell<JSBundlerPlugin>(vm)) JSBundlerPlugin(vm, structure, target);
        ptr->finishCreation(vm);
        return ptr;
    }

    DECLARE_INFO;
    template<typename, SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<JSBundlerPlugin, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForBundlerPlugin.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForBundlerPlugin = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForBundlerPlugin.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForBundlerPlugin = std::forward<decltype(space)>(space); });
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    DECLARE_VISIT_CHILDREN;
    DECLARE_VISIT_OUTPUT_CONSTRAINTS;

    template<typename Visitor> void visitAdditionalChildrenInGCThread(Visitor&);

    Bun::BundlerPlugin plugin;
    JSC::LazyProperty<JSBundlerPlugin, JSC::JSFunction> onLoadFunction;
    JSC::LazyProperty<JSBundlerPlugin, JSC::JSFunction> onResolveFunction;
    JSC::LazyProperty<JSBundlerPlugin, JSC::JSFunction> setupFunction;
    Vector<JSC::WriteBarrier<NapiExternal>> nativePluginExternals;

    static void destroy(JSC::JSCell* cell)
    {
        JSBundlerPlugin* thisObject = static_cast<JSBundlerPlugin*>(cell);
        thisObject->~JSBundlerPlugin();
    }

private:
    JSBundlerPlugin(JSC::VM& vm, JSC::Structure* structure, BunPluginTarget target)
        : Base(vm, structure)
        , plugin(vm, target)
    {
    }

    ~JSBundlerPlugin() = default;
    void finishCreation(JSC::VM&);
};

} // namespace Bun
