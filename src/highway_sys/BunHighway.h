#ifndef BUN_HIGHWAY_H
#define BUN_HIGHWAY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#define BUN_HIGHWAY_NOEXCEPT noexcept
#else
#define BUN_HIGHWAY_NOEXCEPT
#endif

void* highway_memmem(const void* haystack, size_t haystack_length, const void* needle, size_t needle_length) BUN_HIGHWAY_NOEXCEPT;
size_t highway_index_of_char(const uint8_t* text, size_t length, uint8_t character) BUN_HIGHWAY_NOEXCEPT;
size_t highway_index_of_any_char(const uint8_t* text, size_t length, const uint8_t* characters, size_t character_count) BUN_HIGHWAY_NOEXCEPT;
size_t highway_index_of_interesting_character_in_string_literal(const uint8_t* text, size_t length, uint8_t quote) BUN_HIGHWAY_NOEXCEPT;
size_t highway_index_of_newline_or_non_ascii(const uint8_t* text, size_t length) BUN_HIGHWAY_NOEXCEPT;
size_t highway_index_of_newline_or_non_ascii_or_hash_or_at(const uint8_t* text, size_t length) BUN_HIGHWAY_NOEXCEPT;
size_t highway_index_of_space_or_newline_or_non_ascii(const uint8_t* text, size_t length) BUN_HIGHWAY_NOEXCEPT;
size_t highway_index_of_needs_escape_for_javascript_string(const uint8_t* text, size_t length, uint8_t quote) BUN_HIGHWAY_NOEXCEPT;
uint8_t highway_contains_newline_or_non_ascii_or_quote(const uint8_t* text, size_t length) BUN_HIGHWAY_NOEXCEPT;

// Copies support overlapping ranges. The uint16_t input may be unaligned.
void highway_copy_u16_to_u8(const void* input, size_t element_count, uint8_t* output) BUN_HIGHWAY_NOEXCEPT;
void highway_fill_with_skip_mask(const uint8_t mask[4], uint8_t* output, const uint8_t* input, size_t length, uint8_t skip_mask) BUN_HIGHWAY_NOEXCEPT;
uint64_t highway_xxhash3_64(const uint8_t* input, size_t length, uint64_t seed) BUN_HIGHWAY_NOEXCEPT;

#ifdef __cplusplus
}
#endif
#undef BUN_HIGHWAY_NOEXCEPT

#endif
