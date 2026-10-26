#include "BunHighway.h"
#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "Strings.cpp"
#include <hwy/foreach_target.h> // Must come before highway.h

#include <hwy/highway.h>
#include <hwy/aligned_allocator.h>

#include <hwy/contrib/algo/find-inl.h>

#include <cstring>
#include <algorithm>
#include <bit>
#include <cstdlib>
#include <cstddef>
#include <cstdint>

HWY_BEFORE_NAMESPACE();
namespace bun {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

using D8 = hn::ScalableTag<uint8_t>;

size_t IndexOfCharImpl(const uint8_t* HWY_RESTRICT haystack, size_t haystack_len,
    uint8_t needle)
{
    D8 d;
    const size_t pos = hn::Find<D8>(d, needle, haystack, haystack_len);

    return (pos < haystack_len) ? pos : haystack_len;
}

size_t IndexOfAnyCharImpl(const uint8_t* HWY_RESTRICT text, size_t text_len, const uint8_t* HWY_RESTRICT chars, size_t chars_len)
{
    if (text_len == 0 || chars_len == 0) return text_len;
    if (chars_len == 1) return IndexOfCharImpl(text, text_len, chars[0]);
    if (chars_len > 16) {
        bool members[256] {};
        for (size_t i = 0; i < chars_len; ++i)
            members[chars[i]] = true;
        for (size_t i = 0; i < text_len; ++i) {
            if (members[text[i]]) return i;
        }
        return text_len;
    }
    D8 d;
    const size_t N = hn::Lanes(d);

    if (chars_len == 2) {
        // 2 character implemenation
        // covers the most common case:
        //
        // - { '\r', '\n' }
        // - { '\\', '/' }
        // - { ' ', '\t' }
        //
        const auto vec_char1 = hn::Set(d, chars[0]);
        const auto vec_char2 = hn::Set(d, chars[1]);

        size_t i = 0;
        const size_t simd_text_len = text_len - (text_len % N);
        for (; i < simd_text_len; i += N) {
            const auto text_vec = hn::LoadN(d, text + i, N);
            const auto found_mask = hn::Or(hn::Eq(text_vec, vec_char2), hn::Eq(text_vec, vec_char1));

            const intptr_t pos = hn::FindFirstTrue(d, found_mask);
            if (pos >= 0) {
                return i + pos;
            }
        }

        for (; i < text_len; ++i) {
            const uint8_t text_char = text[i];
            if (text_char == chars[0] || text_char == chars[1]) {
                return i;
            }
        }

        return text_len;
    } else {
        const size_t simd_text_len = text_len - (text_len % N);
        size_t i = 0;

#if !HWY_HAVE_SCALABLE && !HWY_TARGET_IS_SVE
        // Preload search characters into native-width vectors.
        // On non-SVE targets, Vec has a known size and can be stored in arrays.
        static constexpr size_t kMaxPreloadedChars = 16;
        hn::Vec<D8> char_vecs[kMaxPreloadedChars];
        const size_t num_chars_to_preload = std::min(chars_len, kMaxPreloadedChars);
        for (size_t c = 0; c < num_chars_to_preload; ++c) {
            char_vecs[c] = hn::Set(d, chars[c]);
        }

        for (; i < simd_text_len; i += N) {
            const auto text_vec = hn::LoadN(d, text + i, N);
            auto found_mask = hn::MaskFalse(d);

            for (size_t c = 0; c < num_chars_to_preload; ++c) {
                found_mask = hn::Or(found_mask, hn::Eq(text_vec, char_vecs[c]));
            }
#else
        // SVE types are sizeless and cannot be stored in arrays.
        // hn::Set is a single broadcast instruction; the compiler will
        // hoist these loop-invariant broadcasts out of the outer loop.
        for (; i < simd_text_len; i += N) {
            const auto text_vec = hn::LoadN(d, text + i, N);
            auto found_mask = hn::MaskFalse(d);

            for (size_t c = 0; c < chars_len; ++c) {
                found_mask = hn::Or(found_mask, hn::Eq(text_vec, hn::Set(d, chars[c])));
            }
#endif

            const intptr_t pos = hn::FindFirstTrue(d, found_mask);
            if (pos >= 0) {
                return i + pos;
            }
        }

        for (; i < text_len; ++i) {
            const uint8_t text_char = text[i];
            for (size_t c = 0; c < chars_len; ++c) {
                if (text_char == chars[c]) {
                    return i;
                }
            }
        }
    }

    return text_len;
}

void CopyU16ToU8Impl(const uint8_t* input, size_t count, uint8_t* output)
{
    if (count == 0) return;
    if (count > SIZE_MAX / 2) std::abort();
    constexpr size_t lowByte = std::endian::native == std::endian::little ? 0 : 1;
    const uintptr_t inputAddress = reinterpret_cast<uintptr_t>(input);
    const uintptr_t outputAddress = reinterpret_cast<uintptr_t>(output);
    size_t i = 0;
    if (outputAddress > inputAddress && outputAddress - inputAddress < count * 2) {
        // Narrowing overlap changes direction at the byte distance between the ranges.
        // Copy the prefix backwards, then the suffix forwards, to preserve unread units.
        i = std::min(static_cast<size_t>(outputAddress - inputAddress), count);
        for (size_t end = i; end > 0;) {
            --end;
            output[end] = input[end * 2 + lowByte];
        }
    }
    const D8 d;
    const size_t lanes = hn::Lanes(d);
    for (; count - i >= lanes; i += lanes) {
        hn::Vec<D8> even;
        hn::Vec<D8> odd;
        hn::LoadInterleaved2(d, input + i * 2, even, odd);
        hn::StoreU(lowByte == 0 ? even : odd, d, output + i);
    }
    for (; i < count; ++i)
        output[i] = input[i * 2 + lowByte];
}

// Implementation for finding interesting characters in string literals
size_t IndexOfInterestingCharacterInStringLiteralImpl(const uint8_t* HWY_RESTRICT text, size_t text_len, uint8_t quote)
{
    D8 d;
    const size_t N = hn::Lanes(d);

    const auto vec_quote = hn::Set(d, quote);
    const auto vec_backslash = hn::Set(d, '\\');
    const auto vec_min_ascii = hn::Set(d, uint8_t { 0x20 }); // Space
    const auto vec_max_ascii = hn::Set(d, uint8_t { 0x7E }); // ~

    const size_t simd_text_len = text_len - (text_len % N);
    size_t i = 0;
    for (; i < simd_text_len; i += N) {
        const auto text_vec = hn::LoadN(d, text + i, N);

        // Check for quote, backslash, or characters outside printable ASCII range
        const auto mask_quote = hn::Eq(text_vec, vec_quote);
        const auto mask_backslash = hn::Eq(text_vec, vec_backslash);
        const auto mask_lt_min = hn::Lt(text_vec, vec_min_ascii);
        const auto mask_gt_max = hn::Gt(text_vec, vec_max_ascii);

        const auto found_mask = hn::Or(
            hn::Or(mask_quote, mask_backslash),
            hn::Or(mask_lt_min, mask_gt_max));

        const intptr_t pos = hn::FindFirstTrue(d, found_mask);
        if (pos >= 0) {
            return i + pos;
        }
    }

    for (; i < text_len; ++i) {
        const uint8_t c = text[i];
        if (c == quote || c == '\\' || (c < 0x20 || c > 0x7E)) {
            return i;
        }
    }

    return text_len;
}

size_t IndexOfNewlineOrNonASCIIOrHashOrAtImpl(const uint8_t* HWY_RESTRICT start_ptr, size_t search_len)
{

    D8 d;
    const size_t N = hn::Lanes(d);

    const auto vec_hash = hn::Set(d, '#');
    const auto vec_at = hn::Set(d, '@');
    const auto vec_min_ascii = hn::Set(d, uint8_t { 0x20 });
    const auto vec_max_ascii = hn::Set(d, uint8_t { 127 });

    size_t i = 0;
    const size_t simd_text_len = search_len - (search_len % N);
    for (; i < simd_text_len; i += N) {
        const auto vec = hn::LoadU(d, start_ptr + i);

        const auto mask_hash = hn::Eq(vec, vec_hash);
        const auto mask_at = hn::Eq(vec, vec_at);
        const auto mask_lt_min = hn::Lt(vec, vec_min_ascii);
        const auto mask_gt_max = hn::Gt(vec, vec_max_ascii);

        const auto found_mask = hn::Or(hn::Or(mask_hash, mask_at), hn::Or(mask_lt_min, mask_gt_max));

        const intptr_t pos = hn::FindFirstTrue(d, found_mask);
        if (pos >= 0) {
            return i + pos;
        }
    }

    for (; i < search_len; ++i) {
        const uint8_t char_ = start_ptr[i];
        if (char_ == '#' || char_ == '@' || char_ < 0x20 || char_ > 127) {
            return i;
        }
    }

    return search_len;
}

size_t IndexOfNewlineOrNonASCIIImpl(const uint8_t* HWY_RESTRICT start_ptr, size_t search_len)
{

    D8 d;
    const size_t N = hn::Lanes(d);

    // SIMD constants
    const auto vec_max_ascii = hn::Set(d, uint8_t { 127 });
    const auto vec_min_ascii = hn::Set(d, uint8_t { 0x20 });

    size_t i = 0;
    const size_t simd_text_len = search_len - (search_len % N);
    // Process full vectors
    for (; i < simd_text_len; i += N) {
        const auto vec = hn::LoadU(d, start_ptr + i);
        const auto mask_lt_min = hn::Lt(vec, vec_min_ascii);
        const auto mask_gt_max = hn::Gt(vec, vec_max_ascii);

        const auto found_mask = hn::Or(mask_gt_max, mask_lt_min);

        const intptr_t pos = hn::FindFirstTrue(d, found_mask);
        if (pos >= 0) {
            return i + pos;
        }
    }

    // Scalar check for the remainder
    for (; i < search_len; ++i) {
        const uint8_t char_ = start_ptr[i];
        if (char_ > 127 || char_ < 0x20) {
            return i;
        }
    }

    return search_len;
}

size_t IndexOfSpaceOrNewlineOrNonASCIIImpl(const uint8_t* HWY_RESTRICT start_ptr, size_t search_len)
{

    D8 d;
    const size_t N = hn::Lanes(d);

    const uint8_t after_space = ' ' + 1;

    const auto vec_min_ascii_including_space = hn::Set(d, after_space);
    const auto vec_max_ascii = hn::Set(d, uint8_t { 127 });
    size_t simd_text_len = search_len - (search_len % N);

    size_t i = 0;
    for (; i < simd_text_len; i += N) {
        const auto vec = hn::LoadU(d, start_ptr + i);
        const auto mask_lt_min = hn::Lt(vec, vec_min_ascii_including_space);
        const auto mask_gt_max = hn::Gt(vec, vec_max_ascii);
        const auto found_mask = hn::Or(mask_gt_max, mask_lt_min);
        const intptr_t pos = hn::FindFirstTrue(d, found_mask);
        if (pos >= 0) {
            return i + pos;
        }
    }

    for (; i < search_len; ++i) {
        const uint8_t char_ = start_ptr[i];
        if (char_ <= ' ' || char_ > 127) {
            return i;
        }
    }

    return search_len;
}

bool ContainsNewlineOrNonASCIIOrQuoteImpl(const uint8_t* HWY_RESTRICT text, size_t text_len)
{

    D8 d;
    const size_t N = hn::Lanes(d);

    // SIMD constants
    const auto vec_max_ascii = hn::Set(d, uint8_t { 127 });
    const auto vec_min_ascii = hn::Set(d, uint8_t { 0x20 });
    const auto vec_quote = hn::Set(d, uint8_t { '"' });

    size_t i = 0;
    const size_t simd_text_len = text_len - (text_len % N);

    // Process full vectors
    for (; i < simd_text_len; i += N) {
        const auto vec = hn::LoadU(d, text + i);
        const auto mask_lt_min = hn::Lt(vec, vec_min_ascii);
        const auto mask_gt_max = hn::Gt(vec, vec_max_ascii);

        const auto mask_quote_eq = hn::Eq(vec, vec_quote);

        const auto found_mask = hn::Or(hn::Or(mask_gt_max, mask_lt_min), mask_quote_eq);

        if (!hn::AllFalse(d, found_mask)) {
            return true;
        }
    }

    // Scalar check for the remainder
    for (; i < text_len; ++i) {
        const uint8_t char_ = text[i];
        if (char_ > 127 || char_ < 0x20 || char_ == '"') {
            return true;
        }
    }

    return false;
}

template<bool is_backtick>
static size_t IndexOfNeedsEscapeForJavaScriptStringImpl(const uint8_t* HWY_RESTRICT text, size_t text_len, uint8_t quote_char)
{

    D8 d;
    const size_t N = hn::Lanes(d);

    // Set up SIMD constants
    const auto vec_backslash = hn::Set(d, uint8_t { '\\' });
    const auto vec_min_ascii = hn::Set(d, uint8_t { 0x20 });
    const auto vec_max_ascii = hn::Set(d, uint8_t { 0x7E });
    const auto vec_quote = hn::Set(d, quote_char);

    const auto vec_dollar = hn::Set(d, uint8_t { '$' });

    // Calculate how many full SIMD vectors we can process
    const size_t simd_text_len = text_len - (text_len % N);
    size_t i = 0;

    // Process chunks of the string
    for (; i < simd_text_len; i += N) {
        const auto text_vec = hn::LoadN(d, text + i, N);

        // Check for characters that need escaping
        const auto mask_gt_max = hn::Gt(text_vec, vec_max_ascii);
        const auto mask_lt_min = hn::Lt(text_vec, vec_min_ascii);
        const auto mask_backslash = hn::Eq(text_vec, vec_backslash);
        const auto mask_quote = hn::Eq(text_vec, vec_quote);

        auto found_mask = !is_backtick ? hn::Or(
                                             hn::Or(mask_gt_max, mask_lt_min),
                                             hn::Or(mask_backslash, mask_quote))
                                       : hn::Or(
                                             hn::Or(
                                                 hn::Or(mask_gt_max, mask_lt_min),
                                                 hn::Or(mask_backslash, mask_quote)),
                                             hn::Eq(text_vec, vec_dollar));

        const intptr_t pos = hn::FindFirstTrue(d, found_mask);
        if (pos >= 0) {
            return i + pos;
        }
    }

    // Scalar check for the remainder
    for (; i < text_len; ++i) {
        const uint8_t char_ = text[i];
        if (char_ >= 127 || char_ < 0x20 || char_ == '\\' || char_ == quote_char || (is_backtick && char_ == '$')) {
            return i;
        }
    }

    return text_len; // No characters needing escape found
}

size_t IndexOfNeedsEscapeForJavaScriptStringImplBacktick(const uint8_t* HWY_RESTRICT text, size_t text_len, uint8_t quote_char)
{
    return IndexOfNeedsEscapeForJavaScriptStringImpl<true>(text, text_len, quote_char);
}

size_t IndexOfNeedsEscapeForJavaScriptStringImplQuote(const uint8_t* HWY_RESTRICT text, size_t text_len, uint8_t quote_char)
{
    return IndexOfNeedsEscapeForJavaScriptStringImpl<false>(text, text_len, quote_char);
}

// Highway implementation of memmem
// Returns a pointer to the first occurrence of `needle` in `haystack`,
// or nullptr if not found. The return type is non-const `uint8_t*`
// to match the standard C `memmem` signature, even though the input
// is const. The caller should handle constness appropriately.
uint8_t* MemMemImpl(const uint8_t* haystack, size_t haystack_len,
    const uint8_t* needle, size_t needle_len)
{
    // --- Edge Cases ---
    if (HWY_UNLIKELY(needle_len == 0)) {
        return const_cast<uint8_t*>(haystack);
    }
    if (HWY_UNLIKELY(haystack_len < needle_len)) {
        return nullptr;
    }
    if (HWY_UNLIKELY(needle_len == 1)) {
        size_t index = IndexOfCharImpl(haystack, haystack_len, needle[0]);
        if (index != haystack_len) {
            return const_cast<uint8_t*>(haystack + index);
        }
        return nullptr;
    }

    // --- SIMD Setup ---
    const hn::ScalableTag<uint8_t> d;
    const size_t N = hn::Lanes(d);
    const uint8_t first_needle_char = needle[0];
    const hn::Vec<decltype(d)> v_first_needle = hn::Set(d, first_needle_char);
    const size_t candidate_count = haystack_len - needle_len + 1;
    const size_t vector_end = candidate_count - candidate_count % N;
    size_t i = 0;
    for (; i < vector_end; i += N) {
        const hn::Vec<decltype(d)> haystack_vec = hn::LoadU(d, haystack + i);
        hn::Mask<decltype(d)> m_starts = hn::Eq(haystack_vec, v_first_needle);

        // Iterate through potential matches within this vector chunk using FindFirstTrue
        while (!hn::AllFalse(d, m_starts)) {
            const intptr_t bit_idx_ptr = hn::FindFirstTrue(d, m_starts);
            // Loop condition guarantees FindFirstTrue finds something
            HWY_ASSERT(bit_idx_ptr >= 0);
            const size_t bit_idx = static_cast<size_t>(bit_idx_ptr);

            const size_t potential_pos = i + bit_idx;

            if (memcmp(haystack + potential_pos, needle, needle_len) == 0) {
                return const_cast<uint8_t*>(haystack + potential_pos);
            }

            // Clear the found bit to find the next one in the next iteration.
            // SetOnlyFirst creates a mask with only the first true bit set.
            // AndNot removes that bit from m_starts.
            const hn::Mask<decltype(d)> first_bit_mask = hn::SetOnlyFirst(m_starts);
            m_starts = hn::AndNot(first_bit_mask, m_starts);
        }
    }
    for (; i < candidate_count; ++i) {
        if (haystack[i] == first_needle_char && memcmp(haystack + i, needle, needle_len) == 0)
            return const_cast<uint8_t*>(haystack + i);
    }
    return nullptr;
}

void FillWithSkipMaskImpl(const uint8_t* mask, uint8_t* output, const uint8_t* input, size_t length, bool skip_mask)
{
    if (length == 0) return;
    if (skip_mask) {
        std::memmove(output, input, length);
        return;
    }
    uint8_t mask_bytes[4];
    std::memcpy(mask_bytes, mask, sizeof(mask_bytes));
    const uintptr_t input_address = reinterpret_cast<uintptr_t>(input);
    const uintptr_t output_address = reinterpret_cast<uintptr_t>(output);
    if (output_address > input_address && output_address - input_address < length) {
        std::memmove(output, input, length);
        input = output;
    }
    D8 d;
    const size_t N = hn::Lanes(d);
    alignas(HWY_ALIGNMENT) uint8_t mask_pattern[HWY_MAX_LANES_D(D8) + 3];
    for (size_t i = 0; i < sizeof(mask_pattern); ++i)
        mask_pattern[i] = mask_bytes[i % 4];
    size_t i = 0;
    const size_t vector_length = length - (length % N);
    for (; i < vector_length; i += N) {
        const auto input_vec = hn::LoadU(d, input + i);
        const auto mask_vec = hn::LoadU(d, mask_pattern + i % 4);
        const auto masked_vec = hn::Xor(input_vec, mask_vec);
        hn::StoreU(masked_vec, d, output + i);
    }
    for (; i < length; ++i)
        output[i] = input[i] ^ mask_bytes[i % 4];
}

} // namespace HWY_NAMESPACE
} // namespace bun
HWY_AFTER_NAMESPACE();

// HWY_ONCE ensures this block is only included once,
// in the final pass after all target-specific code is generated.
#if HWY_ONCE

namespace bun {

// Define the dispatch tables. The names here must exactly match
// the *Impl function names defined within the HWY_NAMESPACE block above.
HWY_EXPORT(ContainsNewlineOrNonASCIIOrQuoteImpl);
HWY_EXPORT(CopyU16ToU8Impl);
HWY_EXPORT(FillWithSkipMaskImpl);
HWY_EXPORT(IndexOfAnyCharImpl);
HWY_EXPORT(IndexOfCharImpl);
HWY_EXPORT(IndexOfInterestingCharacterInStringLiteralImpl);
HWY_EXPORT(IndexOfNeedsEscapeForJavaScriptStringImplBacktick);
HWY_EXPORT(IndexOfNeedsEscapeForJavaScriptStringImplQuote);
HWY_EXPORT(IndexOfNewlineOrNonASCIIImpl);
HWY_EXPORT(IndexOfNewlineOrNonASCIIOrHashOrAtImpl);
HWY_EXPORT(IndexOfSpaceOrNewlineOrNonASCIIImpl);
HWY_EXPORT(MemMemImpl);
// Define the C-callable wrappers that use HWY_DYNAMIC_DISPATCH.
// These need to be defined *after* the HWY_EXPORT block and INSIDE namespace bun
// so that HWY_DYNAMIC_DISPATCH(FuncImpl) correctly resolves to bun::N_*::FuncImpl.
// The extern "C" only affects linkage (for C callers), not namespace resolution.
extern "C" {

void* highway_memmem(const void* haystack, size_t haystack_len, const void* needle, size_t needle_len) noexcept
{
    return HWY_DYNAMIC_DISPATCH(MemMemImpl)(static_cast<const uint8_t*>(haystack), haystack_len, static_cast<const uint8_t*>(needle), needle_len);
}

void highway_copy_u16_to_u8(const void* input, size_t count, uint8_t* output) noexcept
{
    HWY_DYNAMIC_DISPATCH(CopyU16ToU8Impl)(static_cast<const uint8_t*>(input), count, output);
}

size_t highway_index_of_any_char(const uint8_t* HWY_RESTRICT text, size_t text_len, const uint8_t* HWY_RESTRICT chars, size_t chars_len) noexcept
{
    return HWY_DYNAMIC_DISPATCH(IndexOfAnyCharImpl)(text, text_len, chars, chars_len);
}

size_t highway_index_of_char(const uint8_t* HWY_RESTRICT haystack, size_t haystack_len,
    uint8_t needle) noexcept
{
    return HWY_DYNAMIC_DISPATCH(IndexOfCharImpl)(haystack, haystack_len, needle);
}

size_t highway_index_of_interesting_character_in_string_literal(const uint8_t* HWY_RESTRICT text, size_t text_len, uint8_t quote) noexcept
{
    return HWY_DYNAMIC_DISPATCH(IndexOfInterestingCharacterInStringLiteralImpl)(text, text_len, quote);
}

size_t highway_index_of_newline_or_non_ascii(const uint8_t* HWY_RESTRICT haystack, size_t haystack_len) noexcept
{
    return HWY_DYNAMIC_DISPATCH(IndexOfNewlineOrNonASCIIImpl)(haystack, haystack_len);
}

size_t highway_index_of_newline_or_non_ascii_or_hash_or_at(const uint8_t* HWY_RESTRICT haystack, size_t haystack_len) noexcept
{
    return HWY_DYNAMIC_DISPATCH(IndexOfNewlineOrNonASCIIOrHashOrAtImpl)(haystack, haystack_len);
}

uint8_t highway_contains_newline_or_non_ascii_or_quote(const uint8_t* HWY_RESTRICT text, size_t text_len) noexcept
{
    return HWY_DYNAMIC_DISPATCH(ContainsNewlineOrNonASCIIOrQuoteImpl)(text, text_len);
}

size_t highway_index_of_needs_escape_for_javascript_string(const uint8_t* HWY_RESTRICT text, size_t text_len, uint8_t quote_char) noexcept
{
    if (quote_char == '`') {
        return HWY_DYNAMIC_DISPATCH(IndexOfNeedsEscapeForJavaScriptStringImplBacktick)(text, text_len, quote_char);
    } else {
        return HWY_DYNAMIC_DISPATCH(IndexOfNeedsEscapeForJavaScriptStringImplQuote)(text, text_len, quote_char);
    }
}

size_t highway_index_of_space_or_newline_or_non_ascii(const uint8_t* HWY_RESTRICT text, size_t text_len) noexcept
{
    return HWY_DYNAMIC_DISPATCH(IndexOfSpaceOrNewlineOrNonASCIIImpl)(text, text_len);
}

void highway_fill_with_skip_mask(
    const uint8_t mask[4],
    uint8_t* output,
    const uint8_t* input,
    size_t length,
    uint8_t skip_mask) noexcept
{
    HWY_DYNAMIC_DISPATCH(FillWithSkipMaskImpl)(mask, output, input, length, skip_mask != 0);
}

} // extern "C"

} // namespace bun

#if defined(__APPLE__)
// On macOS, override the libc memmem with our implementation
// This uses inline assembly to ensure the symbol is exported with the correct name
__asm__(".globl _memmem");
__asm__(".set _memmem, _highway_memmem");
#elif defined(__linux__)
// On Linux, override the libc memmem with our implementation
// This uses the GNU-specific attribute to alias our function to the libc symbol
// The alias will be visible across the entire program, not just this file
extern "C" {
// Default visibility keeps the executable's implementation available to every
// linked component rather than limiting interposition to this object file.
__attribute__((visibility("default"), used)) void* memmem(const void* haystack, size_t haystacklen, const void* needle, size_t needlelen)
    noexcept
    __attribute__((alias("highway_memmem")));
}

#endif

#endif // HWY_ONCE
