#pragma once

#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/Symbol.h>
#include <wtf/text/StringView.h>

namespace Bun::Bindgen {

inline bool isWorkerSharedEnvironment(JSC::JSValue value) noexcept
{
    if (!value.isSymbol())
        return false;
    auto& uid = JSC::asSymbol(value)->uid();
    return uid.isRegistered() && WTF::StringView(uid) == "nodejs.worker_threads.SHARE_ENV"_s;
}

}
