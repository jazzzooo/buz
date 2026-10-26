#pragma once

#include "SchemaBindings.h"

using ResolvedSource = Bun::Bindgen::ResolvedSourceRecordResult;
using BunLoaderType = Bun::Bindgen::BunLoaderType;

inline bool resolvedSourceHasKind(const ResolvedSource& source, Bun::Bindgen::ResolvedSourceKind kind)
{
    return source.tag.is_source() && source.tag.source() == kind;
}

inline void releaseResolvedSourceResources(ResolvedSource& source)
{
    if (source.bytecodeCache) {
        Bun::Bindgen::Engine::releaseExternalBytesOwner(*source.bytecodeCache);
        source.bytecodeCache.reset();
    }
    if (source.moduleInfo) {
        Bun::Bindgen::Engine::releaseModuleInfoDeserialized(*source.moduleInfo);
        source.moduleInfo.reset();
    }
}

class ResolvedSourceResult : public Bun::Bindgen::ResolvedSourceOutcomeResult {
    using Base = Bun::Bindgen::ResolvedSourceOutcomeResult;

public:
    ResolvedSourceResult() = default;
    ResolvedSourceResult(Base&& source)
        : Base(std::move(source))
    {
        source = {};
    }
    ResolvedSourceResult(ResolvedSourceResult&& source)
        : Base(std::move(source))
    {
        static_cast<Base&>(source) = {};
    }
    ResolvedSourceResult(const ResolvedSourceResult&) = delete;

    ~ResolvedSourceResult()
    {
        reset();
    }

    ResolvedSourceResult& operator=(Base&& source)
    {
        reset();
        Base::operator=(std::move(source));
        source = {};
        return *this;
    }

    ResolvedSourceResult& operator=(ResolvedSourceResult&& source)
    {
        if (this == &source)
            return *this;
        reset();
        Base::operator=(std::move(source));
        static_cast<Base&>(source) = {};
        return *this;
    }

    ResolvedSourceResult& operator=(const ResolvedSourceResult&) = delete;

    void set_value(ResolvedSource source)
    {
        reset();
        Base::set_value(std::move(source));
    }

    void set_errorValue(JSC::JSValue value)
    {
        reset();
        Base::set_errorValue(value);
    }

    void reset()
    {
        if (is_value())
            releaseResolvedSourceResources(value());
        Base::operator=(Base {});
    }
};
