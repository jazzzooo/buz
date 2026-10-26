#pragma once

#include "StructuredSerializeOptions.h"
#include <JavaScriptCore/JSCInlines.h>
#include <optional>

namespace Bun::Bindgen {

inline std::optional<WebCore::StructuredSerializeOptions> structuredSerializeOptionsFromTransfer(
    JSC::JSGlobalObject& globalObject,
    const WTF::Vector<JSC::JSValue>* values)
{
    WTF::Vector<JSC::Strong<JSC::JSObject>> transfer;
    if (values) {
        if (!transfer.tryReserveCapacity(values->size())) {
            auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
            JSC::throwOutOfMemoryError(&globalObject, scope);
            return std::nullopt;
        }
        for (auto value : *values) {
            auto* object = value.getObject();
            RELEASE_ASSERT(object);
            transfer.append({ globalObject.vm(), object });
        }
    }
    return WebCore::StructuredSerializeOptions { WTF::move(transfer) };
}

template<typename Second>
std::optional<WebCore::StructuredSerializeOptions> structuredSerializeOptionsFromBinding(
    JSC::JSGlobalObject& globalObject,
    const std::optional<Second>& second)
{
    const WTF::Vector<JSC::JSValue>* values = nullptr;
    if (second) {
        if (second->is_transfer()) {
            values = &second->transfer();
        } else {
            RELEASE_ASSERT(second->is_options());
            if (second->options().transfer)
                values = &*second->options().transfer;
        }
    }
    return structuredSerializeOptionsFromTransfer(globalObject, values);
}

}
