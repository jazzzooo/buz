/*
 * Copyright (C) 1999 Lars Knoll (knoll@kde.org)
 *           (C) 1999 Antti Koivisto (koivisto@kde.org)
 *           (C) 2001 Dirk Mueller (mueller@kde.org)
 * Copyright (C) 2004-2021 Apple Inc. All rights reserved.
 * Copyright (C) 2006 Alexey Proskuryakov (ap@webkit.org)
 *           (C) 2007, 2008 Nikolas Zimmermann <zimmermann@kde.org>
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include "config.h"
#include "Event.h"
#include "EventPath.h"

#include "EventTarget.h"

#include "AddEventListenerOptions.h"
#include "DOMWrapperWorld.h"
#include "EventNames.h"
#include "EventTargetConcrete.h"
// #include "HTMLBodyElement.h"
// #include "HTMLHtmlElement.h"
// #include "InspectorInstrumentation.h"
#include "JSErrorHandler.h"
#include "JSEventListener.h"
#include "JSDOMExceptionHandling.h"
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <JavaScriptCore/VM.h>
// #include "Logging.h"
// #include "Quirks.h"
// #include "ScriptController.h"
// #include "ScriptDisallowedScope.h"
// #include "Settings.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Ref.h>
#include <wtf/SetForScope.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include "ErrorCode.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(EventTarget);

Ref<EventTarget> EventTarget::create(ScriptExecutionContext& context)
{
    return EventTargetConcrete::create(context);
}

EventTarget::~EventTarget()
{
    // The WeakPtrImpl (and its EventTargetData) can outlive this object.
    if (auto* data = this->eventTargetData())
        data->clear();
}

bool EventTarget::isNode() const
{
    return false;
}

bool EventTarget::isContextStopped() const
{
    return !scriptExecutionContext();
}

bool EventTarget::isPaymentRequest() const
{
    return false;
}

Bun::Bindgen::NativeAllocationResult<bool> EventTarget::addEventListener(const AtomString& eventType, Ref<EventListener>&& listener, const AddEventListenerOptions& options)
{
    Ref protectedThis { *this };
#if ASSERT_ENABLED
    listener->checkValidityForEventTarget(*this);
#endif

    if (options.signal && options.signal->aborted())
        return false;

    auto passive = options.passive;

    // if (!passive.has_value() && Quirks::shouldMakeEventListenerPassive(*this, eventType, listener.get()))
    //     passive = true;

    auto registration = ensureEventTargetData().eventListenerMap.add(eventType, listener.copyRef(), { options.capture, passive.value_or(false), options.once });
    if (!registration)
        return Bun::Bindgen::nativeAllocationFailure();
    auto* registeredListener = *registration;
    if (!registeredListener)
        return false;

    if (options.signal)
        options.signal->addEventListenerAbortAlgorithm(*registeredListener, *this, eventType);

    // if (listenerCreatedFromScript)
    //     InspectorInstrumentation::didAddEventListener(*this, eventType, listener.get(), options.capture);

    eventListenersDidChange();
    if (this->onDidChangeListener) [[unlikely]] {
        this->onDidChangeListener(*this, eventType, OnDidChangeListenerKind::Add);
    }
    return true;
}

void EventTarget::addEventListenerForBindings(JSC::JSGlobalObject& globalObject, const AtomString& eventType, RefPtr<EventListener>&& listener, AddEventListenerOptionsOrBoolean&& variant)
{
    if (!listener)
        return;

    auto visitor = WTF::makeVisitor([&](const AddEventListenerOptions& options) { return addEventListener(eventType, listener.releaseNonNull(), options); }, [&](bool capture) { return addEventListener(eventType, listener.releaseNonNull(), capture); });

    if (!std::visit(visitor, variant)) {
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        JSC::throwOutOfMemoryError(&globalObject, scope);
    }
}

void EventTarget::removeEventListenerForBindings(const AtomString& eventType, RefPtr<EventListener>&& listener, EventListenerOptionsOrBoolean&& variant)
{
    if (!listener)
        return;

    auto visitor = WTF::makeVisitor([&](const EventListenerOptions& options) { removeEventListener(eventType, *listener, options); }, [&](bool capture) { removeEventListener(eventType, *listener, capture); });

    std::visit(visitor, variant);
}

bool EventTarget::removeEventListener(const AtomString& eventType, EventListener& listener, const EventListenerOptions& options)
{
    Ref protectedThis { *this };
    auto* data = eventTargetData();
    if (!data)
        return false;

    // InspectorInstrumentation::willRemoveEventListener(*this, eventType, listener, options.capture);

    if (data->eventListenerMap.remove(eventType, listener, options.capture)) {
        if (this->onDidChangeListener) [[unlikely]] {
            this->onDidChangeListener(*this, eventType, OnDidChangeListenerKind::Remove);
        }
        eventListenersDidChange();
        return true;
    }
    return false;
}

template<typename JSMaybeErrorEventListener>
Bun::Bindgen::NativeAllocationResult<void> EventTarget::setAttributeEventListener(const AtomString& eventType, JSC::JSObject* listener, JSC::JSObject& jsEventTarget)
{
    auto& isolatedWorld = worldForDOMObject(jsEventTarget);
    auto* existingListener = attributeEventListener(eventType, isolatedWorld);
    if (!listener) {
        if (existingListener)
            removeEventListener(eventType, *existingListener, false);
    } else if (existingListener) {
        existingListener->replaceJSFunctionForAttributeListener(listener, &jsEventTarget);
    } else {
        if (!addEventListener(eventType, JSMaybeErrorEventListener::create(*listener, jsEventTarget, true, isolatedWorld), {}))
            return Bun::Bindgen::nativeAllocationFailure();
    }
    if (listener) {
        jsEventTarget.vm().writeBarrier(&jsEventTarget, listener);
        JSC::ensureStillAliveHere(listener);
    }
    return {};
}

template Bun::Bindgen::NativeAllocationResult<void> EventTarget::setAttributeEventListener<JSErrorHandler>(const AtomString& eventType, JSC::JSObject* listener, JSC::JSObject& jsEventTarget);
template Bun::Bindgen::NativeAllocationResult<void> EventTarget::setAttributeEventListener<JSEventListener>(const AtomString& eventType, JSC::JSObject* listener, JSC::JSObject& jsEventTarget);

JSEventListener* EventTarget::attributeEventListener(const AtomString& eventType, DOMWrapperWorld& isolatedWorld)
{
    for (auto& eventListener : eventListeners(eventType)) {
        auto& listener = eventListener->callback();
        if (listener.type() != EventListener::JSEventListenerType)
            continue;

        auto& jsListener = downcast<JSEventListener>(listener);
        if (jsListener.isAttribute() && &jsListener.isolatedWorld() == &isolatedWorld)
            return &jsListener;
    }

    return nullptr;
}

bool EventTarget::hasActiveEventListeners(const AtomString& eventType) const
{
    auto* data = eventTargetData();
    return data && data->eventListenerMap.containsActive(eventType);
}

ExceptionOr<bool> EventTarget::dispatchEventForBindings(Event& event)
{
    if (!event.isInitialized())
        return Exception { InvalidStateError };

    if (event.isBeingDispatched()) {
        return Exception { EVENT_RECURSION, makeString("The event \""_s, event.type(), "\" is already being dispatched"_s) };
    }

    if (!scriptExecutionContext())
        return false;

    event.setUntrusted();

    dispatchEvent(event);
    return event.legacyReturnValue();
}

void EventTarget::dispatchEvent(Event& event)
{
    ASSERT(event.isInitialized());
    ASSERT(!event.isBeingDispatched());

    EventPath eventPath(*this);
    event.setTarget(this);
    event.setCurrentTarget(this);
    event.setEventPhase(Event::AT_TARGET);
    event.resetBeforeDispatch();
    event.setEventPath(eventPath);
    fireEventListeners(event, EventInvokePhase::Capturing);
    fireEventListeners(event, EventInvokePhase::Bubbling);
    event.resetAfterDispatch();
}

void EventTarget::uncaughtExceptionInEventHandler()
{
}

void EventTarget::dispatchSimpleEvent(const AtomString& type)
{
    Ref protectedThis { *this };
    auto* context = scriptExecutionContext();
    if (!context)
        return;
    auto* global = context->globalObject();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(global->vm());
    if (!scope.exception()) {
        auto event = Event::tryCreate(type, Event::CanBubble::No, Event::IsCancelable::No);
        if (event)
            dispatchEvent(*event);
        else {
            auto throwScope = DECLARE_THROW_SCOPE(global->vm());
            JSC::throwOutOfMemoryError(global, throwScope);
        }
    }
    if (auto* exception = scope.exception())
        reportException(global, exception);
}

// https://dom.spec.whatwg.org/#concept-event-listener-invoke
void EventTarget::fireEventListeners(Event& event, EventInvokePhase phase)
{
    ASSERT(event.isInitialized());
    Ref protectedThis { *this };

    auto* data = eventTargetData();
    if (!data)
        return;

    SetForScope firingEventListenersScope(data->isFiringEventListeners, true);

    EventListenerMap::DispatchCursor listeners { data->eventListenerMap, event.type() };
    innerInvokeEventListeners(event, listeners, phase);
}

void EventTarget::innerInvokeEventListeners(Event& event, EventListenerMap::DispatchCursor& listeners, EventInvokePhase phase)
{
    while (auto registeredListener = listeners.next()) {
        auto* context = scriptExecutionContext();
        if (!context)
            break;
        if (registeredListener->wasRemoved()) [[unlikely]]
            continue;

        if (phase == EventInvokePhase::Capturing && !registeredListener->useCapture())
            continue;
        if (phase == EventInvokePhase::Bubbling && registeredListener->useCapture())
            continue;

        // If stopImmediatePropagation has been called, we just break out immediately, without
        // handling any more events on this target.
        if (event.immediatePropagationStopped())
            break;

        // Make sure the JS wrapper and function stay alive until the end of this scope. Otherwise,
        // event listeners with 'once' flag may get collected as soon as they get unregistered below,
        // before we call the js function.
        JSC::EnsureStillAliveScope wrapperProtector(registeredListener->callback().wrapper());
        JSC::EnsureStillAliveScope jsFunctionProtector(registeredListener->callback().jsFunction());

        // Do this before invocation to avoid reentrancy issues.
        if (registeredListener->isOnce())
            removeEventListener(event.type(), registeredListener->callback(), registeredListener->useCapture());

        if (scriptExecutionContext() != context)
            break;

        if (registeredListener->isPassive())
            event.setInPassiveListener(true);

#if ASSERT_ENABLED
        registeredListener->callback().checkValidityForEventTarget(*this);
#endif

        registeredListener->callback().handleEvent(*context, event);

        if (registeredListener->isPassive())
            event.setInPassiveListener(false);
    }
}

Vector<AtomString> EventTarget::eventTypes()
{
    if (auto* data = eventTargetData())
        return data->eventListenerMap.eventTypes();
    return {};
}

const EventListenerVector& EventTarget::eventListeners(const AtomString& eventType)
{
    auto* data = eventTargetData();
    auto* listenerVector = data ? data->eventListenerMap.find(eventType) : nullptr;
    static NeverDestroyed<EventListenerVector> emptyVector;
    return listenerVector ? *listenerVector : emptyVector.get();
}

void EventTarget::removeAllEventListeners()
{
    auto* data = eventTargetData();
    if (!data || data->eventListenerMap.isEmpty())
        return;

    Ref protectedThis { *this };
    auto removed = data->eventListenerMap.takeAll();
    for (auto& entry : removed) {
        if (this->onDidChangeListener) [[unlikely]]
            this->onDidChangeListener(*this, entry.first, OnDidChangeListenerKind::Clear);
    }
    eventListenersDidChange();
}

} // namespace WebCore
