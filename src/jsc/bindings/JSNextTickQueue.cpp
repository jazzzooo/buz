#include "root.h"

#include "JavaScriptCore/JSCJSValueInlines.h"
#include "JavaScriptCore/JSPromise.h"
#include "JavaScriptCore/LazyPropertyInlines.h"
#include <JavaScriptCore/Weak.h>
#include <JavaScriptCore/GetterSetter.h>

#include "JSNextTickQueue.h"
#include "AsyncContextFrame.h"
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/Structure.h>
#include <JavaScriptCore/JSInternalFieldObjectImplInlines.h>
#include <JavaScriptCore/StrongInlines.h>
#include "DOMClientIsoSubspaces.h"
#include "DOMIsoSubspaces.h"
#include "BunClientData.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"

namespace Bun {

using namespace JSC;

const JSC::ClassInfo JSNextTickQueue::s_info = { "NextTickQueue"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSNextTickQueue) };

template<typename, JSC::SubspaceAccess mode>
JSC::GCClient::IsoSubspace* JSNextTickQueue::subspaceFor(JSC::VM& vm)
{
    return WebCore::subspaceForImpl<JSNextTickQueue, WebCore::UseCustomHeapCellType::No>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForJSNextTickQueue.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForJSNextTickQueue = std::forward<decltype(space)>(space); },
        [](auto& spaces) { return spaces.m_subspaceForJSNextTickQueue.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForJSNextTickQueue = std::forward<decltype(space)>(space); });
}

JSNextTickQueue* JSNextTickQueue::create(VM& vm, Structure* structure)
{
    JSNextTickQueue* mod = new (NotNull, allocateCell<JSNextTickQueue>(vm)) JSNextTickQueue(vm, structure);
    mod->finishCreation(vm);
    return mod;
}
Structure* JSNextTickQueue::createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
{
    return Structure::create(vm, globalObject, prototype, TypeInfo(ObjectType, StructureFlags), info());
}

JSNextTickQueue::JSNextTickQueue(VM& vm, Structure* structure)
    : Base(vm, structure)
{
}

void JSNextTickQueue::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    auto values = initialValues();
    for (unsigned index = 0; index < values.size(); ++index)
        internalField(index).set(vm, this, values[index]);
}

template<typename Visitor>
void JSNextTickQueue::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* thisObject = uncheckedDowncast<JSNextTickQueue>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
}

DEFINE_VISIT_CHILDREN(JSNextTickQueue);

JSNextTickQueue* JSNextTickQueue::create(JSC::JSGlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);
    auto* obj = create(vm, createStructure(vm, globalObject, jsNull()));
    return obj;
}

bool JSNextTickQueue::isEmpty()
{
    return internalField(1).get().isNull();
}

JSNextTickQueue::PreparedTask::PreparedTask(VM& vm, JSNextTickQueue& queue, JSArray& task)
    : m_queue(vm, &queue)
    , m_task(vm, &task)
{
}

JSNextTickQueue::PreparedTask::PreparedTask(PreparedTask&& other) noexcept
    : m_consumed(std::exchange(other.m_consumed, true))
{
    m_queue.swap(other.m_queue);
    m_task.swap(other.m_task);
}

void JSNextTickQueue::PreparedTask::commit()
{
    RELEASE_ASSERT(!m_consumed);
    m_consumed = true;
    if (!m_task)
        return;
    m_queue->appendTask(m_queue->vm(), *m_task.get());
    m_task.clear();
    m_queue.clear();
}

std::optional<JSNextTickQueue::PreparedTask> JSNextTickQueue::prepareTask(JSGlobalObject& globalObject, JSValue callback, JSArray* arguments, JSValue receiver)
{
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto context = globalObject.m_asyncContextData.get()->internalField(JSC::InternalFieldTuple::Field::Slot0).get();
    if (auto* frame = dynamicDowncast<AsyncContextFrame>(callback)) {
        context = frame->context.get();
        callback = frame->callback.get();
    }
    RELEASE_ASSERT(callback.isCallable());
    auto* task = constructEmptyArray(&globalObject, nullptr, 5);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    // Private records keep an initialized, boxed next link at index zero.
    task->putDirectIndex(&globalObject, 0, jsNull());
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    task->putDirectIndex(&globalObject, 1, callback);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    task->putDirectIndex(&globalObject, 2, arguments ? JSValue(arguments) : jsUndefined());
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    task->putDirectIndex(&globalObject, 3, context);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    task->putDirectIndex(&globalObject, 4, receiver);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return PreparedTask { vm, *this, *task };
}

void JSNextTickQueue::appendTask(VM& vm, JSArray& task)
{
    if (auto* tail = internalField(3).get().getObject())
        uncheckedDowncast<JSArray>(tail)->setIndexQuickly(vm, 0, &task);
    else
        internalField(1).set(vm, this, &task);
    internalField(3).set(vm, this, &task);
    internalField(0).set(vm, this, jsNumber(1));
}

JSArray* JSNextTickQueue::takeTask(VM& vm)
{
    auto* head = internalField(1).get().getObject();
    if (!head)
        return nullptr;
    auto* task = uncheckedDowncast<JSArray>(head);
    auto next = task->getIndexQuickly(0);
    internalField(1).set(vm, this, next);
    if (next.isNull()) {
        internalField(3).set(vm, this, jsNull());
        internalField(0).set(vm, this, jsNumber(0));
    }
    task->setIndexQuickly(vm, 0, jsNull());
    return task;
}

void JSNextTickQueue::drain(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    bool mustResetContext = false;
    if (isEmpty()) {
        RETURN_IF_EXCEPTION(throwScope, );
        vm.drainMicrotasks();
        RETURN_IF_EXCEPTION(throwScope, );
        mustResetContext = true;
    }

    if (!isEmpty()) {
        RETURN_IF_EXCEPTION(throwScope, );
        if (mustResetContext) {
            globalObject->m_asyncContextData.get()->putInternalField(vm, 0, jsUndefined());
            RETURN_IF_EXCEPTION(throwScope, );
        }
        auto* drainFn = internalField(2).get().getObject();
        MarkedArgumentBuffer drainArgs;
        JSC::call(globalObject, drainFn, drainArgs, "Failed to drain next tick queue"_s);
        RETURN_IF_EXCEPTION(throwScope, );
    }
}

namespace Bindgen::Cpp {

void bunBindgenCpp_next_tick_enqueue(CppCallContext& context, const BunBindgenCpp_next_tick_enqueue_Arguments& args)
{
    auto* global = defaultGlobalObject(&context.globalObject);
    auto* queue = global->m_nextTickQueue.get();
    RELEASE_ASSERT(queue);
    auto* arguments = args.arguments ? uncheckedDowncast<JSArray>(*args.arguments) : nullptr;
    auto task = queue->prepareTask(*global, args.callback, arguments);
    if (task)
        task->commit();
}

std::optional<JSValue> bunBindgenCpp_next_tick_take(CppCallContext& context, const BunBindgenCpp_next_tick_take_Arguments&)
{
    auto* global = defaultGlobalObject(&context.globalObject);
    auto* queue = global->m_nextTickQueue.get();
    RELEASE_ASSERT(queue);
    if (auto* task = queue->takeTask(global->vm()))
        return JSValue(task);
    return std::nullopt;
}

}

}
