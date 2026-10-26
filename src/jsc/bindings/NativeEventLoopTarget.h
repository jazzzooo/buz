#pragma once

#include <wtf/ThreadSafeRefCounted.h>

namespace JSC {
class JSGlobalObject;
}

namespace Bun {

class NativeEventLoopTarget : public WTF::ThreadSafeRefCounted<NativeEventLoopTarget> {
public:
    virtual ~NativeEventLoopTarget() = default;
    virtual void run(JSC::JSGlobalObject*) noexcept = 0;
    virtual void stop() noexcept = 0;
};

}
