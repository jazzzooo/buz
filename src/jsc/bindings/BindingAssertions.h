#pragma once

#include "root.h"

namespace Bun {

ALWAYS_INLINE void assertNoPendingException(JSC::JSGlobalObject* globalObject)
{
#if ASSERT_ENABLED
    DECLARE_TOP_EXCEPTION_SCOPE(globalObject->vm()).assertNoExceptionExceptTermination();
#else
    (void)globalObject;
#endif
}

ALWAYS_INLINE void assertPendingException(JSC::JSGlobalObject* globalObject)
{
#if ASSERT_ENABLED
    EXCEPTION_ASSERT(!!DECLARE_TOP_EXCEPTION_SCOPE(globalObject->vm()).exception());
#else
    (void)globalObject;
#endif
}

}
