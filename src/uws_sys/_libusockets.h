#pragma once

#ifndef LIBUWS_CAPI_HEADER
#define LIBUWS_CAPI_HEADER

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef STRING_POINTER
#define STRING_POINTER
typedef struct StringPointer {
    uint32_t off;
    uint32_t len;
} StringPointer;
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum uws_compress_options_t : int32_t {
    /* These are not actual compression options */
    _COMPRESSOR_MASK = 0x00FF,
    _DECOMPRESSOR_MASK = 0x0F00,
    /* Disabled, shared, shared are "special" values */
    DISABLED = 0,
    SHARED_COMPRESSOR = 1,
    SHARED_DECOMPRESSOR = 1 << 8,
    /* Highest 4 bits describe decompressor */
    DEDICATED_DECOMPRESSOR_32KB = 15 << 8,
    DEDICATED_DECOMPRESSOR_16KB = 14 << 8,
    DEDICATED_DECOMPRESSOR_8KB = 13 << 8,
    DEDICATED_DECOMPRESSOR_4KB = 12 << 8,
    DEDICATED_DECOMPRESSOR_2KB = 11 << 8,
    DEDICATED_DECOMPRESSOR_1KB = 10 << 8,
    DEDICATED_DECOMPRESSOR_512B = 9 << 8,
    /* Same as 32kb */
    DEDICATED_DECOMPRESSOR = 15 << 8,

    /* Lowest 8 bit describe compressor */
    DEDICATED_COMPRESSOR_3KB = 9 << 4 | 1,
    DEDICATED_COMPRESSOR_4KB = 9 << 4 | 2,
    DEDICATED_COMPRESSOR_8KB = 10 << 4 | 3,
    DEDICATED_COMPRESSOR_16KB = 11 << 4 | 4,
    DEDICATED_COMPRESSOR_32KB = 12 << 4 | 5,
    DEDICATED_COMPRESSOR_64KB = 13 << 4 | 6,
    DEDICATED_COMPRESSOR_128KB = 14 << 4 | 7,
    DEDICATED_COMPRESSOR_256KB = 15 << 4 | 8,
    /* Same as 256kb */
    DEDICATED_COMPRESSOR = 15 << 4 | 8
};

enum uws_opcode_t : int32_t {
    CONTINUATION = 0,
    TEXT = 1,
    BINARY = 2,
    CLOSE = 8,
    PING = 9,
    PONG = 10
};

enum uws_sendstatus_t : uint32_t { BACKPRESSURE,
    SUCCESS,
    DROPPED,
    UWS_SEND_OUT_OF_MEMORY };

enum uws_write_status_t : uint8_t {
    UWS_WRITE_COMPLETE,
    UWS_WRITE_BACKPRESSURE,
    UWS_WRITE_OUT_OF_MEMORY,
    UWS_WRITE_CLOSED,
    UWS_WRITE_FAILED
};

struct uws_app_s;
struct uws_req_s;
struct uws_res_s;
struct uws_websocket_s;
struct uws_header_iterator_s;
typedef struct uws_app_s uws_app_t;
typedef struct uws_req_s uws_req_t;
typedef struct uws_res_s uws_res_t;
typedef struct uws_socket_context_s uws_socket_context_t;
typedef struct uws_websocket_s uws_websocket_t;
typedef struct uws_prepared_websocket_upgrade_s uws_prepared_websocket_upgrade_t;

enum uws_websocket_upgrade_error_t : int32_t {
    UWS_WEBSOCKET_UPGRADE_OK,
    UWS_WEBSOCKET_UPGRADE_OUT_OF_MEMORY,
    UWS_WEBSOCKET_UPGRADE_INVALID_EXTENSIONS,
    UWS_WEBSOCKET_UPGRADE_COMPRESSION_INITIALIZATION_FAILED,
    UWS_WEBSOCKET_UPGRADE_INVALID_KEY,
    UWS_WEBSOCKET_UPGRADE_INVALID_PROTOCOL,
    UWS_WEBSOCKET_UPGRADE_INVALID_RESPONSE_STATE
};

uws_prepared_websocket_upgrade_t* uws_res_prepare_upgrade(int ssl, uws_res_t* response,
    const char* key, size_t key_length, const char* protocol, size_t protocol_length,
    const char* extensions, size_t extensions_length, uws_socket_context_t* context,
    uws_websocket_upgrade_error_t* error);
void uws_prepared_websocket_upgrade_destroy(uws_prepared_websocket_upgrade_t* prepared);
bool uws_prepared_websocket_upgrade_add_header(uws_prepared_websocket_upgrade_t* prepared,
    const char* name, size_t name_length, const char* value, size_t value_length);
bool uws_prepared_websocket_upgrade_finish(uws_prepared_websocket_upgrade_t* prepared);
struct us_socket_t* uws_res_upgrade(uws_prepared_websocket_upgrade_t* prepared, void* data);

typedef void (*uws_websocket_handler)(uws_websocket_t* ws);
typedef void (*uws_websocket_message_handler)(uws_websocket_t* ws,
    const char* message,
    size_t length,
    uws_opcode_t opcode);
typedef void (*uws_websocket_ping_pong_handler)(uws_websocket_t* ws,
    const char* message,
    size_t length);
typedef void (*uws_websocket_close_handler)(uws_websocket_t* ws, int code,
    const char* message, size_t length);
typedef void (*uws_websocket_upgrade_handler)(void*, uws_res_t* response,
    uws_req_t* request,
    uws_socket_context_t* context,
    size_t id);

typedef struct {
    uws_compress_options_t compression;
    /* Maximum message size we can receive */
    unsigned int maxPayloadLength;
    /* 2 minutes timeout is good */
    unsigned short idleTimeout;
    /* 64kb backpressure is probably good */
    unsigned int maxBackpressure;
    bool closeOnBackpressureLimit;
    /* This one depends on kernel timeouts and is a bad default */
    bool resetIdleTimeoutOnSend;
    /* A good default, esp. for newcomers */
    bool sendPingsAutomatically;
    /* Maximum socket lifetime in seconds before forced closure (defaults to
     * disabled) */
    unsigned short maxLifetime;

    uws_websocket_upgrade_handler upgrade;
    uws_websocket_handler open;
    uws_websocket_message_handler message;
    uws_websocket_handler drain;
    uws_websocket_ping_pong_handler ping;
    uws_websocket_ping_pong_handler pong;
    uws_websocket_close_handler close;
} uws_socket_behavior_t;

typedef void (*uws_method_handler)(uws_res_t* response, uws_req_t* request,
    void* user_data);
typedef void (*uws_filter_handler)(uws_res_t* response, int, void* user_data);
typedef void (*uws_missing_server_handler)(const char* hostname,
    void* user_data);
typedef void (*uws_get_headers_server_handler)(const char* header_name,
    size_t header_name_size,
    const char* header_value,
    size_t header_value_size,
    void* user_data);

struct us_loop_t* uws_get_loop();
struct us_loop_t* uws_ensure_loop(void *existing_native_loop, struct us_poll_error_t *failure);
void uws_mark_process_exiting(void);

/* Address text is borrowed until the next query of the same kind on this thread. */
uint64_t uws_res_get_remote_address_info(uws_res_t* res, const char** address, int* port, bool* is_ipv6);
uint64_t uws_res_get_local_address_info(uws_res_t* res, const char** address, int* port, bool* is_ipv6);

#ifdef __cplusplus
}
#endif

#endif
