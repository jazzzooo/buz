#pragma once

#include "SchemaBindings+CrashHandler.h"

BUN_BINDGEN_NORETURN static inline void bunPanic(const char* message, size_t length)
{
#ifdef __cplusplus
    Bun::Bindgen::ZigExports::bunBindgenZig_CrashHandlerBindings_panic(
        std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(message), length });
#else
    bunBindgenC_CrashHandlerBindings_panic((const uint8_t*)message, length);
#endif
}

#define BUN_PANIC(message) bunPanic(message, sizeof(message) - 1)
