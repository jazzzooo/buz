#pragma once

#include "BindingRuntimeDeclarations.h"
#include "NativeCell.h"
#include <JavaScriptCore/WeakGCMapInlines.h>
#include <JavaScriptCore/WeakInlines.h>
#include <wtf/Vector.h>
#include <limits>

namespace Bun {

class BindgenWrapperRegistry::Impl {
public:
    struct Realm {
        Realm(JSC::VM& vm, JSC::JSGlobalObject* globalObject, uint64_t generation)
            : global(globalObject)
            , wrappers(vm)
            , generation(generation)
        {
        }

        JSC::Weak<JSC::JSGlobalObject> global;
        JSC::WeakGCMap<uint64_t, JSC::JSObject> wrappers;
        uint64_t generation;
    };

    explicit Impl(JSC::VM& vm)
        : vm(vm)
    {
    }

    Realm& ensureRealm(JSC::JSGlobalObject* global)
    {
        RELEASE_ASSERT(global);
        RELEASE_ASSERT(&global->vm() == &vm);
        for (size_t index = 0; index < realms.size();) {
            auto& realm = realms[index];
            if (!realm->global) {
                realms.removeAt(index);
                continue;
            }
            if (realm->global.get() == global)
                return *realm;
            ++index;
        }
        RELEASE_ASSERT(nextRealmGeneration < std::numeric_limits<uint64_t>::max());
        uint64_t generation = nextRealmGeneration++;
        realms.append(std::make_unique<Realm>(vm, global, generation));
        return *realms.last();
    }

    Realm* findRealm(uint64_t generation) const
    {
        for (auto& realm : realms) {
            if (realm->generation == generation)
                return realm.get();
        }
        return nullptr;
    }

    void add(BindgenWrapperLink* link, void* wrapper, void (*detach)(void*))
    {
        RELEASE_ASSERT(link);
        RELEASE_ASSERT(wrapper);
        RELEASE_ASSERT(detach);
        RELEASE_ASSERT(!link->previous && !link->next && !link->wrapper && !link->detach);
        link->next = wrapperHead;
        if (wrapperHead)
            wrapperHead->previous = link;
        wrapperHead = link;
        link->wrapper = wrapper;
        link->detach = detach;
    }

    void remove(BindgenWrapperLink* link)
    {
        RELEASE_ASSERT(link);
        if (!link->wrapper) {
            RELEASE_ASSERT(!link->previous && !link->next && !link->detach);
            return;
        }
        if (link->previous)
            link->previous->next = link->next;
        else {
            RELEASE_ASSERT(wrapperHead == link);
            wrapperHead = link->next;
        }
        if (link->next)
            link->next->previous = link->previous;
        *link = { };
    }

    void detachAll()
    {
        while (wrapperHead) {
            auto* link = wrapperHead;
            auto* wrapper = link->wrapper;
            auto detach = link->detach;
            remove(link);
            detach(wrapper);
        }
    }

    JSC::VM& vm;
    WTF::Vector<std::unique_ptr<Realm>> realms;
    BindgenWrapperLink* wrapperHead { nullptr };
    uint64_t nextRealmGeneration { 1 };
};

BindgenWrapperRegistry::BindgenWrapperRegistry(JSC::VM& vm)
    : m_impl(std::make_unique<Impl>(vm))
{
}

BindgenWrapperRegistry::~BindgenWrapperRegistry() = default;

uint64_t BindgenWrapperRegistry::ensureRealm(JSC::JSGlobalObject* global)
{
    return m_impl->ensureRealm(global).generation;
}

JSC::JSObject* BindgenWrapperRegistry::get(Bindgen::NativeCellIdentityKey identity) const
{
    auto* realm = m_impl->findRealm(identity.realmGeneration);
    return realm ? realm->wrappers.get(identity.nativeGeneration) : nullptr;
}

void BindgenWrapperRegistry::set(Bindgen::NativeCellIdentityKey identity, JSC::JSObject* wrapper)
{
    auto* realm = m_impl->findRealm(identity.realmGeneration);
    RELEASE_ASSERT(realm);
    RELEASE_ASSERT(identity.nativeGeneration);
    RELEASE_ASSERT(wrapper);
    RELEASE_ASSERT(!realm->wrappers.get(identity.nativeGeneration));
    realm->wrappers.set(identity.nativeGeneration, JSC::Weak<JSC::JSObject>(wrapper));
}

void BindgenWrapperRegistry::remove(Bindgen::NativeCellIdentityKey identity, JSC::JSObject* wrapper)
{
    auto* realm = m_impl->findRealm(identity.realmGeneration);
    if (!realm)
        return;
    auto* current = realm->wrappers.get(identity.nativeGeneration);
    if (current && current != wrapper)
        return;
    realm->wrappers.remove(identity.nativeGeneration);
}

void BindgenWrapperRegistry::add(BindgenWrapperLink* link, void* wrapper, void (*detach)(void*))
{
    m_impl->add(link, wrapper, detach);
}

void BindgenWrapperRegistry::remove(BindgenWrapperLink* link)
{
    m_impl->remove(link);
}

void BindgenWrapperRegistry::detachAll()
{
    m_impl->detachAll();
}

}

namespace Bun::Bindgen {

JSC::JSGlobalObject* wrapperRealm(JSC::JSGlobalObject* global)
{
    return defaultGlobalObject(global);
}

}
