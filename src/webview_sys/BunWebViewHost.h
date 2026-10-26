#ifndef BUN_WEBVIEW_HOST_H
#define BUN_WEBVIEW_HOST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" [[noreturn]] void Bun__WebView__hostMain(int32_t fd) noexcept;
#else
_Noreturn void Bun__WebView__hostMain(int32_t fd);
#endif

#endif
