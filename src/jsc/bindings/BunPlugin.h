#pragma once

#include "root.h"
#include <wtf/text/WTFString.h>
#include "SchemaBindings.h"
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/Strong.h>
#include "helpers.h"

namespace Zig {

using namespace JSC;
using BunPluginTarget = Bun::Bindgen::BunPluginTarget;

class BunPlugin {
public:
    struct VirtualModule {
        JSC::Strong<JSC::JSObject> callback;
        bool isMock { false };
    };
    using VirtualModuleMap = WTF::UncheckedKeyHashMap<String, VirtualModule>;

    // This is a list of pairs of regexps and functions to match against
    class Group {

    public:
        // JavaScriptCore/RegularExpression does exist however it does not JIT
        // We want JIT!
        // TODO: evaluate if using JSInternalFieldImpl(2) is faster
        Vector<JSC::Strong<JSC::RegExp>> filters = {};
        Vector<JSC::Strong<JSC::JSObject>> callbacks = {};
        BunPluginTarget target { BunPluginTarget::bun };

        void append(JSC::VM& vm, JSC::RegExp* filter, JSC::JSObject* func);
        JSObject* find(JSC::JSGlobalObject* globalObj, const String& path);
        void clear()
        {
            filters.clear();
            callbacks.clear();
        }
    };

    class Base {
    public:
        Group fileNamespace = {};
        Vector<String> namespaces = {};
        Vector<Group> groups = {};

        Group* group(const String& namespaceStr)
        {
            if (namespaceStr.isEmpty()) {
                return &fileNamespace;
            }

            for (size_t i = 0; i < namespaces.size(); i++) {
                if (namespaces[i] == namespaceStr) {
                    return &groups[i];
                }
            }

            return nullptr;
        }

        void append(JSC::VM& vm, JSC::RegExp* filter, JSC::JSObject* func, String& namespaceString);

        void clear()
        {
            fileNamespace.clear();
            namespaces.clear();
            groups.clear();
        }
    };

    class OnLoad final : public Base {

    public:
        OnLoad()
            : Base()
        {
        }

        VirtualModuleMap* _Nullable virtualModules = nullptr;
        bool mustDoExpensiveRelativeLookup = false;
        JSC::EncodedJSValue run(JSC::JSGlobalObject* globalObject, const WTF::String& namespaceString, const WTF::String& path);

        bool hasVirtualModules() const { return virtualModules != nullptr; }

        void addModuleMock(JSC::VM& vm, const String& path, JSC::JSObject* mock);

        std::optional<String> resolveVirtualModule(const String& path, const String& from);

        void clear()
        {
            Base::clear();
            delete virtualModules;
            virtualModules = nullptr;
            mustDoExpensiveRelativeLookup = false;
        }

        ~OnLoad()
        {
            if (virtualModules) {
                delete virtualModules;
            }
        }
    };

    class OnResolve final : public Base {

    public:
        OnResolve()
            : Base()
        {
        }

        JSC::EncodedJSValue run(JSC::JSGlobalObject* globalObject, const WTF::String& namespaceString, const WTF::String& path, const WTF::String& importer);
    };
};

class GlobalObject;

} // namespace Zig

namespace Bun {
std::optional<JSC::JSValue> runVirtualModule(Zig::GlobalObject*, const WTF::String& specifier, bool& wasModuleMock);
}
