#pragma once

#include "root.h"

#include "BunBuiltinNames.h"
#include "BunClientData.h"
#include "ZigGlobalObject.h"

#include "JSDOMWrapperCache.h"
#include <JavaScriptCore/WriteBarrier.h>

namespace Zig {

using namespace JSC;
using namespace WebCore;

class ImportMetaObject final : public JSC::JSNonFinalObject {
public:
    using Base = JSC::JSNonFinalObject;

    static constexpr unsigned StructureFlags = Base::StructureFlags | OverridesGetPrototype;

    /// Must be called with a valid url string (for `import.meta.url`)
    static ImportMetaObject* create(JSC::JSGlobalObject* globalObject, const String& url);

    // URL wrappers supply their native href; other values are converted to strings.
    static ImportMetaObject* create(JSC::JSGlobalObject* globalObject, JSValue specifierOrURL);

    // Specifiers are unescaped filesystem paths with an optional query suffix.
    // A literal '?' in a filename cannot be distinguished from that suffix here.
    static ImportMetaObject* createFromSpecifier(JSC::JSGlobalObject* globalObject, const String& specifier);

    static ImportMetaObject* createRequireFunction(VM& vm, JSGlobalObject* lexicalGlobalObject, const WTF::String& pathString);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    template<typename, JSC::SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;

        return WebCore::subspaceForImpl<ImportMetaObject, UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForImportMeta.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForImportMeta = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForImportMeta.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForImportMeta = std::forward<decltype(space)>(space); });
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, bool isBake = false);
    static JSValue getPrototype(JSObject*, JSC::JSGlobalObject* globalObject);

    enum class StringProperty : uint8_t { URL, Path, Directory, File };
    JSString* getStringProperty(JSGlobalObject*, StringProperty);
    JSCell* getRequire(JSGlobalObject*);
    WriteBarrier<JSCell> requireProperty;

private:
    WriteBarrier<JSString> dirProperty;
    WriteBarrier<JSString> urlProperty;
    WriteBarrier<JSString> fileProperty;
    WriteBarrier<JSString> pathProperty;
    static ImportMetaObject* create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure, const WTF::String& url);

    ImportMetaObject(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM&, const WTF::String& url);
};

}
