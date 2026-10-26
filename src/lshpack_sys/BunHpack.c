#include "BunHpack.h"
#include <lshpack.h>
#include <stdlib.h>
#include <string.h>

struct BunHpack {
    struct lshpack_enc encoder;
    struct lshpack_dec decoder;
};

struct BunHpackEncoderTransaction {
    BunHpack* owner;
    struct lshpack_enc encoder;
    uint8_t* scratch;
    size_t scratch_capacity;
};

BunHpack* bun_hpack_create(uint32_t encoder_capacity, uint32_t decoder_capacity)
{
    BunHpack* result = malloc(sizeof(*result));
    if (!result)
        return NULL;
    if (lshpack_enc_init(&result->encoder) != 0) {
        free(result);
        return NULL;
    }
    lshpack_dec_init(&result->decoder);
    lshpack_enc_set_max_capacity(&result->encoder, encoder_capacity);
    lshpack_dec_set_max_capacity(&result->decoder, decoder_capacity);
    return result;
}

void bun_hpack_destroy(BunHpack* self)
{
    lshpack_dec_cleanup(&self->decoder);
    lshpack_enc_cleanup(&self->encoder);
    free(self);
}

void bun_hpack_set_encoder_capacity(BunHpack* self, uint32_t capacity)
{
    lshpack_enc_set_max_capacity(&self->encoder, capacity);
}

void bun_hpack_set_decoder_capacity(BunHpack* self, uint32_t capacity)
{
    lshpack_dec_set_max_capacity(&self->decoder, capacity);
}

int32_t bun_hpack_decode(BunHpack* self, const uint8_t* source, size_t source_length,
    uint8_t* scratch, size_t scratch_length, BunHpackHeader* output)
{
    if (source_length == 0)
        return BUN_HPACK_INVALID_DATA;
    lsxpack_header_t header;
    lsxpack_header_prepare_decode(&header, (char*)scratch, 0, scratch_length);
    const uint8_t* next = source;
    int status = lshpack_dec_decode(&self->decoder, &next, source + source_length, &header);
    switch (status) {
    case LSHPACK_OK:
        break;
    case LSHPACK_END_BLOCK:
        *output = (BunHpackHeader) { .consumed = (size_t)(next - source) };
        return BUN_HPACK_END_BLOCK;
    case LSHPACK_ERR_MORE_BUF:
        return BUN_HPACK_BUFFER_TOO_SMALL;
    case LSHPACK_ERR_TOO_LARGE:
        return BUN_HPACK_HEADER_TOO_LARGE;
    case LSHPACK_ERR_OUT_OF_MEMORY:
        return BUN_HPACK_OUT_OF_MEMORY;
    default:
        return BUN_HPACK_INVALID_DATA;
    }
    *output = (BunHpackHeader) {
        .consumed = (size_t)(next - source),
        .name_offset = (size_t)header.name_offset,
        .name_length = header.name_len,
        .value_offset = (size_t)header.val_offset,
        .value_length = header.val_len,
        .static_index = header.hpack_index != LSHPACK_HDR_UNKNOWN && header.hpack_index <= LSHPACK_HDR_WWW_AUTHENTICATE
            ? header.hpack_index - 1 : 255,
        .never_index = (header.flags & LSXPACK_NEVER_INDEX) != 0,
    };
    return BUN_HPACK_OK;
}

BunHpackEncoderTransaction* bun_hpack_encoder_begin(BunHpack* self)
{
    BunHpackEncoderTransaction* transaction = malloc(sizeof(*transaction));
    if (!transaction)
        return NULL;
    if (lshpack_enc_clone(&transaction->encoder, &self->encoder) != 0) {
        free(transaction);
        return NULL;
    }
    transaction->owner = self;
    transaction->scratch = NULL;
    transaction->scratch_capacity = 0;
    return transaction;
}

int32_t bun_hpack_encoder_encode(BunHpackEncoderTransaction* transaction,
    const uint8_t* name, size_t name_length, const uint8_t* value, size_t value_length,
    uint8_t never_index, uint8_t* destination, size_t destination_length, size_t* written)
{
    if (name_length == 0)
        return BUN_HPACK_INVALID_DATA;
    if (name_length > BUN_HPACK_MAX_HEADER_SIZE || value_length > BUN_HPACK_MAX_HEADER_SIZE - name_length)
        return BUN_HPACK_HEADER_TOO_LARGE;
    size_t header_length = name_length + value_length;
    // A literal needs at most two string-length integers and an indexed-name integer.
    // With this space reserved, lshpack's remaining failure is allocation.
    if (destination_length < header_length + 32)
        return BUN_HPACK_BUFFER_TOO_SMALL;
    if (transaction->scratch_capacity < header_length) {
        uint8_t* scratch = realloc(transaction->scratch, header_length);
        if (!scratch)
            return BUN_HPACK_OUT_OF_MEMORY;
        transaction->scratch = scratch;
        transaction->scratch_capacity = header_length;
    }
    memcpy(transaction->scratch, name, name_length);
    if (value_length)
        memcpy(transaction->scratch + name_length, value, value_length);
    lsxpack_header_t header;
    lsxpack_header_set_offset2(&header, (char*)transaction->scratch, 0, name_length, name_length, value_length);
    if (never_index)
        header.indexed_type = 2;
    uint8_t* next = lshpack_enc_encode(&transaction->encoder, destination, destination + destination_length, &header);
    if (!next || next == destination)
        return BUN_HPACK_OUT_OF_MEMORY;
    *written = (size_t)(next - destination);
    return BUN_HPACK_OK;
}

void bun_hpack_encoder_commit(BunHpack* self, BunHpackEncoderTransaction* transaction)
{
    if (transaction->owner != self)
        abort();
    lshpack_enc_cleanup(&self->encoder);
    self->encoder = transaction->encoder;
    if (STAILQ_EMPTY(&self->encoder.hpe_all_entries))
        STAILQ_INIT(&self->encoder.hpe_all_entries);
    free(transaction->scratch);
    free(transaction);
}

void bun_hpack_encoder_abort(BunHpack* self, BunHpackEncoderTransaction* transaction)
{
    if (transaction->owner != self)
        abort();
    lshpack_enc_cleanup(&transaction->encoder);
    free(transaction->scratch);
    free(transaction);
}
