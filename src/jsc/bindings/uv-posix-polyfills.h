#pragma once

#include "root.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "SchemaBindings+CrashHandler.h"

#if OS(LINUX) || OS(DARWIN) || OS(FREEBSD)

BUN_BINDGEN_NORETURN static inline void __bun_throw_not_implemented(const char* symbol_name)
{
#ifdef __cplusplus
    Bun::Bindgen::ZigExports::bunBindgenZig_CrashHandlerBindings_unsupportedUVFunction(
        std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(symbol_name), strlen(symbol_name) });
#else
    bunBindgenC_CrashHandlerBindings_unsupportedUVFunction((const uint8_t*)symbol_name, strlen(symbol_name));
#endif
}

// libuv headers will use UV_EXTERN
#define UV_EXTERN __attribute__((visibility("default"))) __attribute__((used))

#include <uv.h>

typedef enum {
    UV_CLOCK_PRECISE = 0, /* Use the highest resolution clock available. */
    UV_CLOCK_FAST = 1 /* Use the fastest clock with <= 1ms granularity. */
} uv_clocktype_t;

#endif
