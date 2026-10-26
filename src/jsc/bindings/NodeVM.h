#pragma once

#include "root.h"
#include "ZigGlobalObject.h"
#include "BunGlobalScope.h"

#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/VM.h>

#include "BunClientData.h"
#include <JavaScriptCore/Nodes.h>

namespace Bun {

class NodeVMGlobalObject;
class NodeVMContextOptions;
class CompileFunctionOptions;

namespace NodeVM {

RefPtr<JSC::CachedBytecode> getBytecode(JSGlobalObject* globalObject, JSC::ProgramExecutable* executable, const JSC::SourceCode& source);
RefPtr<JSC::CachedBytecode> getBytecode(JSGlobalObject* globalObject, JSC::ModuleProgramExecutable* executable, const JSC::SourceCode& source);
String stringifyAnonymousFunction(JSGlobalObject* globalObject, const ArgList& args, ThrowScope& scope, int* outOffset);
JSC::EncodedJSValue createCachedData(JSGlobalObject* globalObject, const JSC::SourceCode& source);
bool handleException(JSGlobalObject* globalObject, VM& vm, NakedPtr<JSC::Exception> exception, ThrowScope& throwScope, bool displayErrors);
NodeVMGlobalObject* getGlobalObjectFromContext(JSGlobalObject* globalObject, JSValue contextValue, bool canThrow);
JSC::EncodedJSValue INVALID_ARG_VALUE_VM_VARIATION(JSC::ThrowScope& throwScope, JSC::JSGlobalObject* globalObject, WTF::ASCIILiteral name, JSC::JSValue value);
// For vm.compileFunction we need to return an anonymous function expression. This code is adapted from/inspired by JSC::constructFunction, which is used for function declarations.
JSC::JSFunction* constructAnonymousFunction(JSC::JSGlobalObject* globalObject, const ArgList& args, const SourceOrigin& sourceOrigin, CompileFunctionOptions&& options, JSC::SourceTaintedOrigin sourceTaintOrigin, JSC::JSScope* scope);
JSPromise* importModule(JSGlobalObject* globalObject, JSString* moduleNameValue, RefPtr<JSC::ScriptFetchParameters> parameters, const SourceOrigin& sourceOrigin);
bool isContext(JSC::JSGlobalObject* globalObject, JSValue);
bool isDontContextifyConstant(JSC::JSGlobalObject* globalObject, JSValue value);
bool isUseMainContextDefaultLoaderConstant(JSC::JSGlobalObject* globalObject, JSValue value);

namespace TypePredicates {

bool isScript(JSC::JSValue) noexcept;
bool isContext(JSC::JSGlobalObject&, JSC::JSValue) noexcept;
bool isDontContextifyConstant(JSC::JSGlobalObject&, JSC::JSValue) noexcept;
bool isUseMainContextDefaultLoaderConstant(JSC::JSGlobalObject&, JSC::JSValue) noexcept;
bool isModule(JSC::JSValue) noexcept;
bool isSourceTextModule(JSC::JSValue) noexcept;
bool isSyntheticModule(JSC::JSValue) noexcept;
bool isScriptConstructor(JSC::JSValue) noexcept;
bool isModuleConstructor(JSC::JSValue) noexcept;

}

} // namespace NodeVM

class BaseVMOptions {
public:
    String filename;
    OrdinalNumber lineOffset = OrdinalNumber::fromZeroBasedInt(0);
    OrdinalNumber columnOffset = OrdinalNumber::fromZeroBasedInt(0);

    BaseVMOptions() = default;
    BaseVMOptions(String filename);
    BaseVMOptions(String filename, OrdinalNumber lineOffset, OrdinalNumber columnOffset);
};

class CompileFunctionOptions : public BaseVMOptions {
public:
    WTF::Vector<uint8_t> cachedData;
    JSGlobalObject* parsingContext = nullptr;
    WTF::Vector<JSC::Strong<JSC::JSObject>> contextExtensions;
    bool produceCachedData = false;

    using BaseVMOptions::BaseVMOptions;

};

class NodeVMContextOptions final {
public:
    bool allowStrings = true;
    bool allowWasm = true;
    bool notContextified = false;
};

class NodeVMGlobalObject;

class NodeVMSpecialSandbox final : public JSC::JSNonFinalObject {
public:
    using Base = JSC::JSNonFinalObject;

    static constexpr unsigned StructureFlags = Base::StructureFlags | JSC::OverridesGetOwnPropertySlot;

    static NodeVMSpecialSandbox* create(VM& vm, Structure* structure, NodeVMGlobalObject* globalObject);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;
    template<typename, JSC::SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm);
    static Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype);

    static bool getOwnPropertySlot(JSObject*, JSGlobalObject*, JSC::PropertyName, JSC::PropertySlot&);

    NodeVMGlobalObject* parentGlobal() const { return m_parentGlobal.get(); }

private:
    WriteBarrier<NodeVMGlobalObject> m_parentGlobal;

    NodeVMSpecialSandbox(VM& vm, Structure* structure, NodeVMGlobalObject* globalObject);

    void finishCreation(VM&);
};

// This class represents a sandboxed global object for vm contexts
class NodeVMGlobalObject final : public Bun::GlobalScope {
public:
    using Base = Bun::GlobalScope;

    static constexpr unsigned StructureFlags = Base::StructureFlags | JSC::OverridesGetOwnPropertySlot | JSC::OverridesPut | JSC::OverridesGetOwnPropertyNames | JSC::GetOwnPropertySlotMayBeWrongAboutDontEnum | JSC::ProhibitsPropertyCaching;
    static constexpr JSC::DestructionMode needsDestruction = NeedsDestruction;

    template<typename, JSC::SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm);
    static NodeVMGlobalObject* create(JSC::VM& vm, JSC::Structure* structure, NodeVMContextOptions options, JSValue importer);
    static Structure* createStructure(JSC::VM& vm, JSC::JSValue prototype);
    static const JSC::GlobalObjectMethodTable& globalObjectMethodTable();

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    ~NodeVMGlobalObject();

    void finishCreation(JSC::VM&);
    static void destroy(JSCell* cell);
    void setContextifiedObject(JSC::JSObject* contextifiedObject);
    JSObject* contextifiedObject() const { return m_sandbox.get(); }
    void clearContextifiedObject();
    void sigintReceived();
    bool isNotContextified() const { return m_contextOptions.notContextified; }
    NodeVMSpecialSandbox* specialSandbox() const { return m_specialSandbox.get(); }
    void setSpecialSandbox(NodeVMSpecialSandbox* sandbox) { m_specialSandbox.set(vm(), this, sandbox); }
    JSValue dynamicImportCallback() const { return m_dynamicImportCallback.get(); }

    // Override property access to delegate to contextified object
    static bool getOwnPropertySlot(JSObject*, JSGlobalObject*, JSC::PropertyName, JSC::PropertySlot&);
    static bool put(JSCell*, JSGlobalObject*, JSC::PropertyName, JSC::JSValue, JSC::PutPropertySlot&);
    static void getOwnPropertyNames(JSObject*, JSGlobalObject*, JSC::PropertyNameArrayBuilder&, JSC::DontEnumPropertiesMode);
    static bool defineOwnProperty(JSObject* object, JSGlobalObject* globalObject, PropertyName propertyName, const PropertyDescriptor& descriptor, bool shouldThrow);
    static bool deleteProperty(JSCell* cell, JSGlobalObject* globalObject, PropertyName propertyName, JSC::DeletePropertySlot& slot);
    static JSC::JSPromise* moduleLoaderImportModule(JSGlobalObject*, JSC::JSModuleLoader*, JSC::JSString* moduleNameValue, RefPtr<JSC::ScriptFetchParameters> parameters, const JSC::SourceOrigin&, bool deferred);

private:
    // The contextified object that acts as the global proxy
    WriteBarrier<JSObject> m_sandbox;
    // A special object used when the context is not contextified.
    WriteBarrier<NodeVMSpecialSandbox> m_specialSandbox;
    WriteBarrier<Unknown> m_dynamicImportCallback;
    NodeVMContextOptions m_contextOptions {};

    NodeVMGlobalObject(VM& vm, Structure* structure, NodeVMContextOptions contextOptions, JSValue importer);
};

// Helper functions to create vm contexts and run code
Structure* createNodeVMGlobalObjectStructure(JSC::VM&);
void configureNodeVM(JSC::VM&, Zig::GlobalObject*);

} // namespace Bun
