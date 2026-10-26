#pragma once

#include <stdint.h>
#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <netdb.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

struct us_loop_t;
struct us_connecting_socket_t;
typedef struct bun_dns_request BunDNSRequest;

enum {
    BUN_DNS_READY = 0,
    BUN_DNS_PENDING = 1,
    BUN_DNS_OUT_OF_MEMORY = 2,
    BUN_DNS_INVALID_ARGUMENT = 3,
};

// Lookup borrows the hostname for the call and returns one request reference.
// Failure leaves out_request null. Every returned reference requires release.
uint8_t bun_dns_lookup(struct us_loop_t* loop, const char* hostname, uint16_t port, BunDNSRequest** out_request);

// A subscribed socket keeps its request reference until notification is drained
// or cancel succeeds. Subscribe returns zero on OOM without registering it.
uint8_t bun_dns_subscribe(BunDNSRequest* request, struct us_connecting_socket_t* socket);
uint8_t bun_dns_cancel(BunDNSRequest* request, struct us_connecting_socket_t* socket);
void bun_dns_release(BunDNSRequest* request, uint8_t invalidate);

// Only completed requests have a result. Addresses are immutable and borrowed
// until the caller releases its request reference. Returns a getaddrinfo error.
int32_t bun_dns_result(BunDNSRequest* request, const struct addrinfo** out_addresses);

#ifdef __cplusplus
}
#endif
