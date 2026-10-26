#ifndef BUN_RESOURCES_H
#define BUN_RESOURCES_H

#include <stdint.h>
#include <wchar.h>

typedef struct BunResourceVersion {
    uint16_t major;
    uint16_t minor;
    uint16_t patch;
    uint16_t revision;
} BunResourceVersion;

#ifdef __cplusplus
extern "C" {
#define BUN_RESOURCES_NOEXCEPT noexcept
#else
#define BUN_RESOURCES_NOEXCEPT
#endif

int32_t rescle__setIcon(const wchar_t* executable, const wchar_t* icon) BUN_RESOURCES_NOEXCEPT;
int32_t rescle__setWindowsMetadata(const wchar_t* executable, const wchar_t* icon,
    const wchar_t* title, const wchar_t* publisher, const BunResourceVersion* version,
    const wchar_t* description, const wchar_t* copyright) BUN_RESOURCES_NOEXCEPT;

#ifdef __cplusplus
}
#endif
#undef BUN_RESOURCES_NOEXCEPT

#endif
