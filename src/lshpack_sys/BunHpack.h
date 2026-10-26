#ifndef BUN_LSHPACK_H
#define BUN_LSHPACK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BunHpack BunHpack;
typedef struct BunHpackEncoderTransaction BunHpackEncoderTransaction;

enum {
    BUN_HPACK_OK = 0,
    BUN_HPACK_INVALID_DATA = 1,
    BUN_HPACK_HEADER_TOO_LARGE = 2,
    BUN_HPACK_BUFFER_TOO_SMALL = 3,
    BUN_HPACK_OUT_OF_MEMORY = 4,
    BUN_HPACK_END_BLOCK = 5,
    BUN_HPACK_MAX_HEADER_SIZE = 65535
};

typedef struct {
    size_t consumed;
    size_t name_offset;
    size_t name_length;
    size_t value_offset;
    size_t value_length;
    uint16_t static_index;
    uint8_t never_index;
} BunHpackHeader;

BunHpack* bun_hpack_create(uint32_t encoder_capacity, uint32_t decoder_capacity);
void bun_hpack_destroy(BunHpack*);
void bun_hpack_set_encoder_capacity(BunHpack*, uint32_t);
void bun_hpack_set_decoder_capacity(BunHpack*, uint32_t);
int32_t bun_hpack_decode(BunHpack*, const uint8_t* source, size_t source_length,
    uint8_t* scratch, size_t scratch_length, BunHpackHeader*);
BunHpackEncoderTransaction* bun_hpack_encoder_begin(BunHpack*);
int32_t bun_hpack_encoder_encode(BunHpackEncoderTransaction*,
    const uint8_t* name, size_t name_length, const uint8_t* value, size_t value_length,
    uint8_t never_index, uint8_t* destination, size_t destination_length, size_t* written);
void bun_hpack_encoder_commit(BunHpack*, BunHpackEncoderTransaction*);
void bun_hpack_encoder_abort(BunHpack*, BunHpackEncoderTransaction*);

#ifdef __cplusplus
}
#endif

#endif
