#include "NodeVMModule.h"
#include "SchemaBindings.h"
#include "NodeVMSourceTextModule.h"
#include "NodeVMSyntheticModule.h"

#include "ErrorCode.h"
#include "JSDOMExceptionHandling.h"
#include "JavaScriptCore/ObjectConstructor.h"
#include "JavaScriptCore/JSPromise.h"
#include "JavaScriptCore/Watchdog.h"

#include "../vm/SigintWatcher.h"

namespace Bun {

static NodeVMModule* nodeVMModule(JSC::JSValue value)
{
    auto* module = dynamicDowncast<NodeVMModule>(value);
    RELEASE_ASSERT(module);
    return module;
}

static NodeVMSourceTextModule* nodeVMSourceTextModule(JSC::JSValue value)
{
    auto* module = dynamicDowncast<NodeVMSourceTextModule>(value);
    RELEASE_ASSERT(module);
    return module;
}

static NodeVMSyntheticModule* nodeVMSyntheticModule(JSC::JSValue value)
{
    auto* module = dynamicDowncast<NodeVMSyntheticModule>(value);
    RELEASE_ASSERT(module);
    return module;
}

NodeVMModuleRequest::NodeVMModuleRequest(WTF::String specifier, WTF::HashMap<WTF::String, WTF::String> importAttributes)
    : m_specifier(WTF::move(specifier))
    , m_importAttributes(WTF::move(importAttributes))
{
}

void NodeVMModuleRequest::addImportAttribute(WTF::String key, WTF::String value)
{
    m_importAttributes.set(WTF::move(key), WTF::move(value));
}

JSArray* NodeVMModuleRequest::toJS(JSGlobalObject* globalObject) const
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSArray* array = JSC::constructEmptyArray(globalObject, nullptr, 2);
    RETURN_IF_EXCEPTION(scope, {});

    array->putDirectIndex(globalObject, 0, JSC::jsString(globalObject->vm(), m_specifier));
    RETURN_IF_EXCEPTION(scope, {});

    JSObject* attributes = JSC::constructEmptyObject(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    for (const auto& [key, value] : m_importAttributes) {
        attributes->putDirect(globalObject->vm(), JSC::Identifier::fromString(globalObject->vm(), key), JSC::jsString(globalObject->vm(), value),
            PropertyAttribute::ReadOnly | PropertyAttribute::DontDelete);
        RETURN_IF_EXCEPTION(scope, {});
    }
    array->putDirectIndex(globalObject, 1, attributes);
    RETURN_IF_EXCEPTION(scope, {});

    return array;
}

void setupWatchdog(VM& vm, double timeout, double* oldTimeout, double* newTimeout);

JSValue NodeVMModule::evaluate(JSGlobalObject* globalObject, uint32_t timeout, bool breakOnSigint)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (m_status != Status::Linked && m_status != Status::Evaluated && m_status != Status::Errored) {
        throwError(globalObject, scope, ErrorCode::ERR_VM_MODULE_STATUS, "Module must be linked, evaluated or errored before evaluating"_s);
        return {};
    }

    if (m_status == Status::Evaluated) {
        return m_evaluationResult.get();
    }

    auto* sourceTextThis = dynamicDowncast<NodeVMSourceTextModule>(this);
    auto* syntheticThis = dynamicDowncast<NodeVMSyntheticModule>(this);

#define VM_RETURN_IF_EXCEPTION(scope__, value__)                                                \
    do {                                                                                        \
        if (JSC::Exception* exception = scope__.exception()) {                                  \
            status(Status::Errored);                                                            \
            m_evaluationException.set(vm, this, exception);                                     \
            return value__;                                                                     \
        }                                                                                       \
    } while (false);

    AbstractModuleRecord* record {};
    if (sourceTextThis) {
        record = sourceTextThis->moduleRecord(globalObject);
        VM_RETURN_IF_EXCEPTION(scope, {});
    } else if (syntheticThis) {
        record = syntheticThis->moduleRecord(globalObject);
        VM_RETURN_IF_EXCEPTION(scope, {});
    } else {
        RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("Invalid module type");
    }

    JSValue result {};

    NodeVMGlobalObject* nodeVmGlobalObject = NodeVM::getGlobalObjectFromContext(globalObject, m_context.get(), false);
    VM_RETURN_IF_EXCEPTION(scope, {});
    if (nodeVmGlobalObject) globalObject = nodeVmGlobalObject;

    auto run = [&] {
        if (sourceTextThis) {
            status(Status::Evaluating);
            evaluateDependencies(globalObject, record, timeout, breakOnSigint);
            RETURN_IF_EXCEPTION(scope, );
            sourceTextThis->initializeImportMeta(globalObject);
            RETURN_IF_EXCEPTION(scope, );
        } else if (syntheticThis) {
            syntheticThis->evaluate(globalObject);
            RETURN_IF_EXCEPTION(scope, );
        }
        result = record->evaluate(globalObject, jsUndefined(), jsNumber(static_cast<int32_t>(JSGenerator::ResumeMode::NormalMode)));
        RETURN_IF_EXCEPTION(scope, );
    };

    setSigintReceived(false);

    std::optional<double> oldLimit, newLimit;

    if (timeout != 0) {
        setupWatchdog(vm, timeout, &oldLimit.emplace(), &newLimit.emplace());
    }

    if (breakOnSigint) {
        auto holder = SigintWatcher::hold(nodeVmGlobalObject, this);
        run();
    } else {
        run();
    }

    if (timeout != 0) {
        vm.watchdog()->setTimeLimit(WTF::Seconds::fromMilliseconds(*oldLimit));
    }

    if (vm.hasPendingTerminationException()) {
        vm.drainMicrotasksForGlobalObject(nodeVmGlobalObject);
        DECLARE_TOP_EXCEPTION_SCOPE(vm).clearException();
        vm.clearHasTerminationRequest();
        if (getSigintReceived()) {
            setSigintReceived(false);
            throwError(globalObject, scope, ErrorCode::ERR_SCRIPT_EXECUTION_INTERRUPTED, "Script execution was interrupted by `SIGINT`"_s);
        } else if (timeout != 0) {
            throwError(globalObject, scope, ErrorCode::ERR_SCRIPT_EXECUTION_TIMEOUT, makeString("Script execution timed out after "_s, timeout, "ms"_s));
        } else {
            RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("vm.SourceTextModule evaluation terminated due neither to SIGINT nor to timeout");
        }
    } else {
        setSigintReceived(false);
    }

    VM_RETURN_IF_EXCEPTION(scope, {});

    status(Status::Evaluated);
    m_evaluationResult.set(vm, this, result);
    return result;
#undef VM_RETURN_IF_EXCEPTION
}

NodeVMModule::NodeVMModule(JSC::VM& vm, JSC::Structure* structure, WTF::String identifier, JSValue context, JSValue moduleWrapper)
    : Base(vm, structure)
    , m_identifier(WTF::move(identifier))
    , m_context(context && context.isObject() ? asObject(context) : nullptr, JSC::WriteBarrierEarlyInit)
    , m_moduleWrapper(moduleWrapper, JSC::WriteBarrierEarlyInit)
{
}

void NodeVMModule::evaluateDependencies(JSGlobalObject* globalObject, AbstractModuleRecord* record, uint32_t timeout, bool breakOnSigint)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    for (const auto& request : record->requestedModules()) {
        if (auto iter = m_resolveCache.find(request.m_specifier.string()); iter != m_resolveCache.end()) {
            auto* dependency = uncheckedDowncast<NodeVMModule>(iter->value.get());
            RELEASE_ASSERT(dependency != nullptr);

            if (dependency->status() == Status::Unlinked) {
                if (auto* syntheticDependency = dynamicDowncast<NodeVMSyntheticModule>(dependency)) {
                    syntheticDependency->link(globalObject);
                    RETURN_IF_EXCEPTION(scope, );
                }
            }

            if (dependency->status() == Status::Linked) {
                JSValue dependencyResult = dependency->evaluate(globalObject, timeout, breakOnSigint);
                RETURN_IF_EXCEPTION(scope, );
                RELEASE_ASSERT_WITH_MESSAGE(dynamicDowncast<JSC::JSPromise>(dependencyResult) == nullptr, "TODO(@heimskr): implement async support for node:vm module dependencies");
            }
        }
    }
}

JSValue NodeVMModule::createModuleRecord(JSC::JSGlobalObject* globalObject)
{
    if (auto* thisObject = dynamicDowncast<NodeVMSourceTextModule>(this)) {
        return thisObject->createModuleRecord(globalObject);
    } else if (auto* thisObject = dynamicDowncast<NodeVMSyntheticModule>(this)) {
        thisObject->createModuleRecord(globalObject);
        return jsUndefined();
    }

    RELEASE_ASSERT_NOT_REACHED();
    return jsUndefined();
}

AbstractModuleRecord* NodeVMModule::moduleRecord(JSC::JSGlobalObject* globalObject)
{
    if (auto* thisObject = dynamicDowncast<NodeVMSourceTextModule>(this)) {
        return thisObject->moduleRecord(globalObject);
    } else if (auto* thisObject = dynamicDowncast<NodeVMSyntheticModule>(this)) {
        return thisObject->moduleRecord(globalObject);
    }

    RELEASE_ASSERT_NOT_REACHED();
    return nullptr;
}

JSModuleNamespaceObject* NodeVMModule::namespaceObject(JSC::JSGlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSModuleNamespaceObject* object = m_namespaceObject.get();
    if (object) {
        return object;
    }

    AbstractModuleRecord* amr = this->moduleRecord(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    object = amr->getModuleNamespace(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    if (object) {
        namespaceObject(vm, object);
    }
    RETURN_IF_EXCEPTION(scope, {});

    return object;
}

#define BUN_BINDGEN_OBJECT_SURFACE_NodeVMModulePrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_NodeVMModulePrototype

NodeVMModulePrototype* NodeVMModulePrototype::create(VM& vm, Structure* structure)
{
    NodeVMModulePrototype* prototype = new (NotNull, allocateCell<NodeVMModulePrototype>(vm)) NodeVMModulePrototype(vm, structure);
    prototype->finishCreation(vm);
    return prototype;
}

Structure* NodeVMModulePrototype::createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
{
    return Structure::create(vm, globalObject, prototype, TypeInfo(ObjectType, StructureFlags), info());
}

NodeVMModulePrototype::NodeVMModulePrototype(VM& vm, Structure* structure)
    : Base(vm, structure)
{
}

void NodeVMModulePrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    bunBindgenObjectSurface_NodeVMModulePrototype_install(vm, info(), *this);
    this->structure()->setMayBePrototype(true);
}

WTF::String Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleIdentifier(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleIdentifier_Arguments& args)
{
    return nodeVMModule(args.bindingThis)->identifier();
}

static EncodedJSValue moduleGetNamespace(JSC::JSGlobalObject* globalObject, NodeVMModule* thisObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    RELEASE_AND_RETURN(scope, JSValue::encode(thisObject->namespaceObject(globalObject)));
}

static EncodedJSValue moduleGetError(JSC::JSGlobalObject* globalObject, NodeVMModule* thisObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (JSC::Exception* exception = thisObject->evaluationException())
        return JSValue::encode(exception->value());
    throwError(globalObject, scope, ErrorCode::ERR_VM_MODULE_STATUS, "Module status must be errored"_s);
    return {};
}

static EncodedJSValue moduleGetModuleRequests(JSC::JSGlobalObject* globalObject, NodeVMModule* thisObject)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (auto* sourceTextModule = dynamicDowncast<NodeVMSourceTextModule>(thisObject)) {
        sourceTextModule->ensureModuleRecord(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
    }

    const WTF::Vector<NodeVMModuleRequest>& requests = thisObject->moduleRequests();

    JSArray* array = constructEmptyArray(globalObject, nullptr, requests.size());
    RETURN_IF_EXCEPTION(scope, {});

    for (unsigned i = 0; const NodeVMModuleRequest& request : requests) {
        array->putDirectIndex(globalObject, i++, request.toJS(globalObject));
        RETURN_IF_EXCEPTION(scope, {});
    }

    return JSValue::encode(array);
}

static EncodedJSValue moduleEvaluate(JSC::JSGlobalObject* globalObject, NodeVMModule* thisObject, uint32_t timeout, bool breakOnSigint)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    RELEASE_AND_RETURN(scope, JSValue::encode(thisObject->evaluate(globalObject, timeout, breakOnSigint)));
}

static EncodedJSValue moduleLink(JSC::JSGlobalObject* globalObject, NodeVMSourceTextModule* thisObject, const WTF::Vector<WTF::String>& specifiers, const WTF::Vector<JSC::JSValue>& moduleValues)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (specifiers.size() != moduleValues.size()) {
        throwVMError(globalObject, scope, "specifiers and moduleNatives must have the same length"_s);
        return {};
    }

    WTF::Vector<NodeVMModule*> moduleNatives;
    moduleNatives.reserveInitialCapacity(moduleValues.size());
    for (auto value : moduleValues)
        moduleNatives.append(nodeVMModule(value));

    RELEASE_AND_RETURN(scope, JSValue::encode(thisObject->link(globalObject, specifiers, moduleNatives)));
}

static EncodedJSValue moduleInstantiate(JSC::JSGlobalObject* globalObject, NodeVMModule* thisObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (auto* sourceTextModule = dynamicDowncast<NodeVMSourceTextModule>(thisObject)) {
        RELEASE_AND_RETURN(scope, JSValue::encode(sourceTextModule->instantiate(globalObject)));
    }

    if (auto* syntheticModule = dynamicDowncast<NodeVMSyntheticModule>(thisObject)) {
        RELEASE_AND_RETURN(scope, JSValue::encode(syntheticModule->instantiate(globalObject)));
    }

    throwTypeError(globalObject, scope, "This function must be called on a SourceTextModule or SyntheticModule"_s);
    return {};
}

static EncodedJSValue moduleSetExport(JSC::JSGlobalObject* globalObject, NodeVMSyntheticModule* thisObject, const WTF::String& name, JSValue exportValue)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    thisObject->setExport(globalObject, name, exportValue);
    RETURN_IF_EXCEPTION(scope, {});

    return JSC::encodedJSUndefined();
}

static EncodedJSValue moduleCreateCachedData(JSC::JSGlobalObject* globalObject, NodeVMSourceTextModule* thisObject)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    RELEASE_AND_RETURN(scope, JSValue::encode(thisObject->cachedData(globalObject)));
}

static EncodedJSValue moduleCreateModuleRecord(JSC::JSGlobalObject* globalObject, NodeVMModule* thisObject)
{
    return JSValue::encode(thisObject->createModuleRecord(globalObject));
}

uint32_t Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleGetStatusCode(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleGetStatusCode_Arguments& args)
{
    return static_cast<uint32_t>(nodeVMModule(args.bindingThis)->status());
}

WTF::String Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleGetStatus(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleGetStatus_Arguments& args)
{
    using enum NodeVMModule::Status;
    switch (nodeVMModule(args.bindingThis)->status()) {
    case Unlinked:
        return "unlinked"_s;
    case Linking:
        return "linking"_s;
    case Linked:
        return "linked"_s;
    case Evaluating:
        return "evaluating"_s;
    case Evaluated:
        return "evaluated"_s;
    case Errored:
        return "errored"_s;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleGetNamespace(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleGetNamespace_Arguments& args)
{
    return JSValue::decode(moduleGetNamespace(&context.globalObject, nodeVMModule(args.bindingThis)));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleGetError(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleGetError_Arguments& args)
{
    return JSValue::decode(moduleGetError(&context.globalObject, nodeVMModule(args.bindingThis)));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleGetModuleRequests(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleGetModuleRequests_Arguments& args)
{
    return JSValue::decode(moduleGetModuleRequests(&context.globalObject, nodeVMModule(args.bindingThis)));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleEvaluate(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleEvaluate_Arguments& args)
{
    return JSValue::decode(moduleEvaluate(
        &context.globalObject,
        nodeVMModule(args.bindingThis),
        args.timeout && args.timeout->has_value() ? **args.timeout : 0,
        args.breakOnSigint && args.breakOnSigint->has_value() ? **args.breakOnSigint : false));
}

void Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleLink(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleLink_Arguments& args)
{
    (void)JSValue::decode(moduleLink(
        &context.globalObject,
        nodeVMSourceTextModule(args.bindingThis),
        args.specifiers,
        args.moduleNatives));
}

void Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleInstantiate(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleInstantiate_Arguments& args)
{
    (void)JSValue::decode(moduleInstantiate(&context.globalObject, nodeVMModule(args.bindingThis)));
}

void Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleSetExport(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleSetExport_Arguments& args)
{
    (void)JSValue::decode(moduleSetExport(
        &context.globalObject,
        nodeVMSyntheticModule(args.bindingThis),
        args.name,
        args.value.value_or(jsUndefined())));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleCreateCachedData(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleCreateCachedData_Arguments& args)
{
    return JSValue::decode(moduleCreateCachedData(&context.globalObject, nodeVMSourceTextModule(args.bindingThis)));
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleCreateModuleRecord(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleCreateModuleRecord_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto result = JSValue::decode(moduleCreateModuleRecord(&context.globalObject, nodeVMModule(args.bindingThis)));
    RETURN_IF_EXCEPTION(scope, {});
    scope.release();
    if (result.isUndefined())
        return std::nullopt;
    return result;
}

template<typename Visitor>
void NodeVMModule::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* vmModule = uncheckedDowncast<NodeVMModule>(cell);
    ASSERT_GC_OBJECT_INHERITS(vmModule, info());
    Base::visitChildren(vmModule, visitor);

    visitor.append(vmModule->m_namespaceObject);
    visitor.append(vmModule->m_context);
    visitor.append(vmModule->m_evaluationResult);
    visitor.append(vmModule->m_moduleWrapper);
    visitor.append(vmModule->m_evaluationException);

    // m_resolveCache is mutated on the mutator thread by
    // NodeVMSourceTextModule::link() via m_resolveCache.set(), which can
    // rehash and free the old bucket array while a concurrent marker is
    // iterating values() here. Both sides take cellLock() (same pattern as
    // AbstractModuleRecord::visitChildrenImpl / setImportedModule).
    WTF::Locker locker { vmModule->cellLock() };
    auto moduleNatives = vmModule->m_resolveCache.values();
    visitor.append(moduleNatives.begin(), moduleNatives.end());
}

DEFINE_VISIT_CHILDREN(NodeVMModule);

template<typename Arguments>
static EncodedJSValue constructSourceTextModule(JSGlobalObject* globalObject, const Arguments& args)
{
    auto& vm = globalObject->vm();
    WTF::Vector<uint8_t> cachedData;
    if (args.cachedData)
        cachedData = *args.cachedData;
    return JSValue::encode(NodeVMSourceTextModule::create(
        vm,
        globalObject,
        args.identifier,
        args.context ? JSC::asObject(*args.context) : globalObject,
        args.sourceText,
        args.lineOffset,
        args.columnOffset,
        WTF::move(cachedData),
        args.initializeImportMeta.value_or(jsUndefined()),
        args.moduleWrapper.value_or(jsUndefined()),
        args.dynamicImportCallback.value_or(jsUndefined())));
}

template<typename Arguments>
static EncodedJSValue constructSyntheticModule(JSGlobalObject* globalObject, const Arguments& args)
{
    return JSValue::encode(NodeVMSyntheticModule::create(
        globalObject->vm(),
        globalObject,
        args.identifier,
        args.context ? JSC::asObject(*args.context) : globalObject,
        args.exportNames,
        args.syntheticEvaluationSteps.value_or(jsUndefined()),
        args.moduleWrapper));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleConstructorCall_overload_source_text(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleConstructorCall_overload_source_text_Arguments& args)
{
    return JSValue::decode(constructSourceTextModule(&context.globalObject, args));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleConstructorCall_overload_synthetic(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleConstructorCall_overload_synthetic_Arguments& args)
{
    return JSValue::decode(constructSyntheticModule(&context.globalObject, args));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleConstructorConstruct_overload_source_text(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleConstructorConstruct_overload_source_text_Arguments& args)
{
    return JSValue::decode(constructSourceTextModule(&context.globalObject, args));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeVM_moduleConstructorConstruct_overload_synthetic(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeVM_moduleConstructorConstruct_overload_synthetic_Arguments& args)
{
    return JSValue::decode(constructSyntheticModule(&context.globalObject, args));
}

NodeVMModuleConstructor* NodeVMModuleConstructor::create(VM& vm, JSGlobalObject* globalObject, Structure* structure, JSObject* prototype)
{
    NodeVMModuleConstructor* ptr = new (NotNull, allocateCell<NodeVMModuleConstructor>(vm)) NodeVMModuleConstructor(vm, structure);
    ptr->finishCreation(vm, prototype);
    return ptr;
}

NodeVMModuleConstructor::NodeVMModuleConstructor(VM& vm, Structure* structure)
    : NodeVMModuleConstructor::Base(vm, structure, bun_bindgen_host_NodeVM_moduleConstructorCall, bun_bindgen_host_NodeVM_moduleConstructorConstruct)
{
}

JSC::Structure* NodeVMModuleConstructor::createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
{
    return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::InternalFunctionType, Base::StructureFlags), info());
}

void NodeVMModuleConstructor::finishCreation(VM& vm, JSObject* prototype)
{
    Base::finishCreation(vm, 1, "Module"_s, PropertyAdditionMode::WithStructureTransition);
    putDirectWithoutTransition(vm, vm.propertyNames->prototype, prototype, PropertyAttribute::DontEnum | PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    ASSERT(inherits(info()));
}

const JSC::ClassInfo NodeVMModule::s_info = { "NodeVMModule"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NodeVMModule) };
const JSC::ClassInfo NodeVMModulePrototype::s_info = { "NodeVMModule"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NodeVMModulePrototype) };
const JSC::ClassInfo NodeVMModuleConstructor::s_info = { "Module"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(NodeVMModuleConstructor) };

} // namespace Bun
