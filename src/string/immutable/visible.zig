pub fn visibleCodepointWidth(cp: u32, ambiguousAsWide: bool) u3_fast {
    return widthFromProperties(unicode.get(cp), ambiguousAsWide);
}

fn widthFromProperties(properties: unicode.Properties, ambiguousAsWide: bool) u3_fast {
    return switch (properties.width) {
        .zero => 0,
        .narrow => 1,
        .wide => 2,
        .ambiguous => if (ambiguousAsWide) 2 else 1,
    };
}

pub const visible = struct {
    // Returns a 16-bit bitmask of which lanes in `chunk` are printable Latin-1
    // (i.e. not C0 control, not DEL/C1, not soft hyphen). Used by the unrolled
    // SIMD width loop — popCount the bitmask to get the printable count.
    fn printableMaskLatin1(chunk: @Vector(16, u8)) u16 {
        const lo: @Vector(16, u8) = @splat(0x20);
        const c1_lo: @Vector(16, u8) = @splat(0x7F);
        const c1_hi: @Vector(16, u8) = @splat(0x9F);
        const ad: @Vector(16, u8) = @splat(0xAD);

        const ge_20 = chunk >= lo;
        const not_c1 = (chunk < c1_lo) | (chunk > c1_hi);
        const not_ad = chunk != ad;
        const printable = @select(bool, ge_20, not_c1, @as(@Vector(16, bool), @splat(false))) &
            not_ad;
        return @bitCast(@as(@Vector(16, u1), @bitCast(printable)));
    }

    // Ref: https://cs.stanford.edu/people/miles/iso8859.html
    fn visibleLatin1Width(input_: []const u8, ambiguousAsWide: bool) usize {
        if (ambiguousAsWide) {
            var length: usize = 0;
            for (input_) |cp| length += widthFromProperties(unicode.get(cp), true);
            return length;
        }

        var length: usize = 0;
        var input_ptr = input_.ptr;
        const input_end = input_.ptr + input_.len;

        // 4x prologue: process 64 bytes per iteration. Each per-chunk popcount
        // is independent and pipelines, only summing into the scalar accumulator
        // every 64 bytes — amortizes the addv→fmov hazard that caps throughput
        // on the no-control-char fast path.
        while (@intFromPtr(input_end) - @intFromPtr(input_ptr) >= 64) : (input_ptr += 64) {
            const c0: @Vector(16, u8) = input_ptr[0..16].*;
            const c1: @Vector(16, u8) = input_ptr[16..32].*;
            const c2: @Vector(16, u8) = input_ptr[32..48].*;
            const c3: @Vector(16, u8) = input_ptr[48..64].*;
            length += @as(usize, @popCount(printableMaskLatin1(c0))) +
                @as(usize, @popCount(printableMaskLatin1(c1))) +
                @as(usize, @popCount(printableMaskLatin1(c2))) +
                @as(usize, @popCount(printableMaskLatin1(c3)));
        }

        // 1x SIMD tail.
        while (@intFromPtr(input_end) - @intFromPtr(input_ptr) >= 16) : (input_ptr += 16) {
            const chunk: @Vector(16, u8) = input_ptr[0..16].*;
            length += @popCount(printableMaskLatin1(chunk));
        }

        // Scalar tail.
        while (input_ptr != input_end) : (input_ptr += 1) {
            length += visibleLatin1WidthScalar(input_ptr[0]);
        }
        return length;
    }

    fn visibleLatin1WidthScalar(c: u8) u1 {
        // Zero-width: control chars (0x00-0x1F, 0x7F-0x9F) and soft hyphen (0xAD)
        return if ((c >= 127 and c <= 159) or c < 32 or c == 0xAD) 0 else 1;
    }

    // SIMD scan for the first lane in the inclusive range [Lo, Hi]. Returns
    // null if not found. Used to find the CSI final byte (0x40-0x7E). Same
    // wrapping-subtract trick as the C++ ANSI helpers:
    //   c in [Lo, Hi]  <=>  (c - Lo) <= (Hi - Lo) unsigned
    fn scanLaneInRange(comptime T: type, comptime Lo: T, comptime Hi: T, slice: []const T) ?usize {
        comptime bun.assert(Lo <= Hi);
        const stride = 16 / @sizeOf(T);
        const MaskInt = @Int(.unsigned, stride);
        var i: usize = 0;
        const lo: @Vector(stride, T) = @splat(Lo);
        const range: @Vector(stride, T) = @splat(Hi - Lo);

        while (slice.len - i >= stride) : (i += stride) {
            const chunk: @Vector(stride, T) = slice[i..][0..stride].*;
            const shifted = chunk -% lo;
            const in_range = shifted <= range;
            const mask: MaskInt = @bitCast(@as(@Vector(stride, u1), @bitCast(in_range)));
            if (mask != 0) return i + @ctz(mask);
        }
        while (i < slice.len) : (i += 1) {
            const c = slice[i];
            if (c -% Lo <= Hi - Lo) return i;
        }
        return null;
    }

    // SIMD scan for the first lane equal to any of `targets`. Returns null if
    // not found. Used to find OSC terminators (BEL/ESC and the C1 ST 0x9C).
    fn scanLaneAnyOf(comptime T: type, comptime targets: []const T, slice: []const T) ?usize {
        comptime bun.assert(targets.len > 0);
        const stride = 16 / @sizeOf(T);
        const MaskInt = @Int(.unsigned, stride);
        var i: usize = 0;

        while (slice.len - i >= stride) : (i += stride) {
            const chunk: @Vector(stride, T) = slice[i..][0..stride].*;
            var hit: @Vector(stride, bool) = chunk == @as(@Vector(stride, T), @splat(targets[0]));
            inline for (targets[1..]) |t| {
                hit = hit | (chunk == @as(@Vector(stride, T), @splat(t)));
            }
            const mask: MaskInt = @bitCast(@as(@Vector(stride, u1), @bitCast(hit)));
            if (mask != 0) return i + @ctz(mask);
        }
        while (i < slice.len) : (i += 1) {
            const c = slice[i];
            inline for (targets) |t| {
                if (c == t) return i;
            }
        }
        return null;
    }

    fn visibleLatin1WidthExcludeANSIColors(input_: anytype, ambiguousAsWide: bool) usize {
        var length: usize = 0;
        var input = input_;

        const ElementType = std.meta.Child(@TypeOf(input_));
        const indexFn = if (comptime ElementType == u8) strings.indexOfCharUsize else strings.indexOfChar16Usize;

        while (indexFn(input, '\x1b')) |i| {
            length += visibleLatin1Width(input[0..i], ambiguousAsWide);
            input = input[i..];

            if (input.len < 2) return length;

            if (input[1] == '[') {
                // CSI sequence: ESC [ <params> <final byte>
                // Final byte is in range 0x40-0x7E (@ through ~). SIMD-scan
                // for it instead of stepping byte-by-byte; CSI parameters can
                // be 1-15+ bytes (e.g. ESC [ 1;31;48;2;255;0;0 m).
                if (input.len < 3) return length;
                input = input[2..];
                if (scanLaneInRange(u8, 0x40, 0x7E, input)) |t| {
                    input = input[t + 1 ..];
                } else {
                    return length;
                }
            } else if (input[1] == ']') {
                // OSC sequence: ESC ] ... (BEL or ST). The payload is opaque
                // (titles, hyperlinks, filenames) — SIMD-scan for the
                // terminators instead of byte-by-byte. Terminators per ECMA-48
                // and xterm: BEL (0x07), C1 ST (0x9C), or 7-bit ST (ESC \).
                input = input[2..];
                while (scanLaneAnyOf(u8, &.{ 0x07, 0x9c, 0x1b }, input)) |t| {
                    const term = input[t];
                    if (term == 0x07 or term == 0x9c) {
                        // Single-byte terminator (BEL or C1 ST).
                        input = input[t + 1 ..];
                        break;
                    }
                    // ESC at offset t — check if next byte is '\\' (ST = ESC \).
                    if (t + 1 < input.len and input[t + 1] == '\\') {
                        input = input[t + 2 ..];
                        break;
                    }
                    // Stray ESC inside OSC payload — skip it and keep scanning.
                    input = input[t + 1 ..];
                } else input = input[input.len..];
            } else {
                input = input[1..];
            }
        }

        length += visibleLatin1Width(input, ambiguousAsWide);

        return length;
    }

    fn visibleUTF8WidthFn(input: []const u8, comptime asciiFn: anytype, ambiguousAsWide: bool) usize {
        var bytes = input;
        var len: usize = 0;
        while (bun.strings.firstNonASCII(bytes)) |i| {
            len += asciiFn(bytes[0..i], false);
            const this_chunk = bytes[i..];
            const byte = this_chunk[0];

            const skip = bun.strings.wtf8ByteSequenceLength(byte);
            const cp_bytes: [4]u8 = switch (@min(@as(usize, skip), this_chunk.len)) {
                inline 1, 2, 3, 4 => |cp_len| .{
                    byte,
                    if (comptime cp_len > 1) this_chunk[1] else 0,
                    if (comptime cp_len > 2) this_chunk[2] else 0,
                    if (comptime cp_len > 3) this_chunk[3] else 0,
                },
                else => unreachable,
            };

            const cp = if (skip > 1) decodeWTF8RuneTMultibyte(&cp_bytes, skip, u32, unicode_replacement) else unicode_replacement;
            len += visibleCodepointWidth(cp, ambiguousAsWide);

            bytes = bytes[@min(i + skip, bytes.len)..];
        }

        len += asciiFn(bytes, false);

        return len;
    }

    /// Packed state for grapheme tracking - all small fields in one u32
    const PackedState = packed struct(u32) {
        non_emoji_width: u10 = 0, // Accumulated width (max 1024)
        base_width: u2 = 0, // Width of first codepoint (0, 1, or 2)
        count: u8 = 0, // Number of codepoints in grapheme
        // Flags
        emoji_base: bool = false,
        keycap: bool = false,
        regional_indicator: bool = false,
        skin_tone: bool = false,
        zwj: bool = false,
        vs15: bool = false,
        vs16: bool = false,
        _pad: u5 = 0,
    };

    const GraphemeState = struct {
        s: PackedState = .{},

        inline fn reset(self: *GraphemeState, cp: u32, ambiguousAsWide: bool) void {
            // Fast path for ASCII - no emoji complexity, simple width calculation
            if (cp < 0x80) {
                const w: u2 = if (cp >= 0x20 and cp < 0x7F) 1 else 0;
                self.s = .{ .count = 1, .base_width = w, .non_emoji_width = w };
                return;
            }

            const properties = unicode.get(cp);
            const w = widthFromProperties(properties, ambiguousAsWide);

            self.s = .{
                .count = 1,
                .base_width = @truncate(w),
                .non_emoji_width = w,
                .emoji_base = properties.emoji,
                .keycap = cp == 0x20E3,
                .regional_indicator = properties.grapheme_break == .regional_indicator,
                .skin_tone = properties.emoji_modifier,
                .zwj = cp == 0x200D,
            };
        }

        fn add(self: *GraphemeState, cp: u32, ambiguousAsWide: bool) void {
            const properties = unicode.get(cp);
            self.s.count +|= 1;
            self.s.keycap = self.s.keycap or (cp == 0x20E3);
            self.s.regional_indicator = self.s.regional_indicator or
                properties.grapheme_break == .regional_indicator;
            self.s.skin_tone = self.s.skin_tone or properties.emoji_modifier;
            self.s.zwj = self.s.zwj or (cp == 0x200D);
            self.s.vs15 = self.s.vs15 or (cp == 0xFE0E);
            self.s.vs16 = self.s.vs16 or (cp == 0xFE0F);

            self.s.non_emoji_width +|= widthFromProperties(properties, ambiguousAsWide);
        }

        inline fn width(self: *const GraphemeState) usize {
            const s = self.s;
            if (s.count == 0) return 0;

            // Regional indicator pair (flag emoji) → width 2
            if (s.regional_indicator and s.count >= 2) return 2;
            // Keycap sequence → width 2
            if (s.keycap) return 2;
            // Single regional indicator → width 1
            if (s.regional_indicator) return 1;
            // Emoji with skin tone or ZWJ → width 2
            if (s.emoji_base and (s.skin_tone or s.zwj)) return 2;

            // Handle variation selectors
            if (s.vs15 or s.vs16) {
                if (s.base_width == 2) return 2;
                if (s.vs16 and s.emoji_base) return 2;
                return s.non_emoji_width;
            }

            return s.non_emoji_width;
        }
    };

    /// Count printable ASCII characters (0x20-0x7E) in a UTF-16 slice using SIMD.
    /// 4x-unrolled main loop: process 32 u16s (64 bytes) per iteration, summing
    /// 4 popcounts. Same hazard amortization as visibleLatin1Width.
    fn countPrintableAscii16(input: []const u16) usize {
        var total: usize = 0;
        var remaining = input;

        const vec_len = 8;
        const low: @Vector(vec_len, u16) = @splat(0x20);
        const high: @Vector(vec_len, u16) = @splat(0x7F);

        const printableMask = struct {
            inline fn f(chunk: @Vector(vec_len, u16), l: @Vector(vec_len, u16), h: @Vector(vec_len, u16)) u8 {
                const ge_low = chunk >= l;
                const lt_high = chunk < h;
                const printable = @select(bool, ge_low, lt_high, @as(@Vector(vec_len, bool), @splat(false)));
                return @bitCast(@as(@Vector(vec_len, u1), @bitCast(printable)));
            }
        }.f;

        // 4x prologue: 32 u16s = 64 bytes per iteration.
        while (remaining.len >= 4 * vec_len) {
            const c0: @Vector(vec_len, u16) = remaining[0..vec_len].*;
            const c1: @Vector(vec_len, u16) = remaining[vec_len..][0..vec_len].*;
            const c2: @Vector(vec_len, u16) = remaining[2 * vec_len ..][0..vec_len].*;
            const c3: @Vector(vec_len, u16) = remaining[3 * vec_len ..][0..vec_len].*;
            total += @as(usize, @popCount(printableMask(c0, low, high))) +
                @as(usize, @popCount(printableMask(c1, low, high))) +
                @as(usize, @popCount(printableMask(c2, low, high))) +
                @as(usize, @popCount(printableMask(c3, low, high)));
            remaining = remaining[4 * vec_len ..];
        }

        // 1x SIMD tail.
        while (remaining.len >= vec_len) {
            const chunk: @Vector(vec_len, u16) = remaining[0..vec_len].*;
            total += @popCount(printableMask(chunk, low, high));
            remaining = remaining[vec_len..];
        }

        // Scalar tail.
        for (remaining) |c| {
            total += @intFromBool(c >= 0x20 and c < 0x7F);
        }

        return total;
    }

    fn visibleUTF16WidthFn(input_: []const u16, exclude_ansi_colors: bool, ambiguousAsWide: bool) usize {
        var input = input_;
        var len: usize = 0;
        // Grapheme state spans ANSI escapes, so only visible codepoints affect it.
        var prev_visible: ?u32 = null;
        var break_state: grapheme.BreakState = .default;
        var grapheme_state = GraphemeState{};
        var saw_1b = false;
        var saw_csi = false; // CSI: ESC [
        var saw_osc = false; // OSC: ESC ]

        while (true) {
            {
                const idx = firstNonASCII16(input) orelse input.len;

                // Fast path: bulk ASCII processing when not in escape sequence
                // ASCII chars are always their own graphemes, so we can count directly
                if (idx > 0 and !saw_1b and !saw_csi and !saw_osc) {
                    // Find how much we can bulk process
                    // If stripping ANSI, stop at first ESC; otherwise process entire run
                    const bulk_end = if (exclude_ansi_colors)
                        strings.indexOfChar16Usize(input[0..idx], 0x1b) orelse idx
                    else
                        idx;

                    if (bulk_end > 0) {
                        // Flush any pending grapheme from previous non-ASCII
                        if (grapheme_state.s.count > 0) {
                            len += grapheme_state.width();
                        }

                        // Count all but last char in bulk using SIMD
                        // Last char goes into grapheme_state in case combining mark follows
                        if (bulk_end > 1) {
                            len += countPrintableAscii16(input[0 .. bulk_end - 1]);
                        }

                        // Last char before ESC (or end) uses reset()
                        const last_cp: u32 = input[bulk_end - 1];
                        grapheme_state.reset(last_cp, ambiguousAsWide);
                        prev_visible = last_cp;
                        break_state = .default;

                        // If we consumed everything, advance and continue
                        if (bulk_end == idx) {
                            input = input[idx..];
                            continue;
                        }

                        // Otherwise we hit ESC - start escape sequence handling
                        saw_1b = true;
                        input = input[bulk_end + 1 ..];
                        continue;
                    }
                }

                var j: usize = 0;
                while (j < idx) {
                    // Bulk SIMD scans inside escape states — replace the byte-by-byte
                    // walk for long CSI parameter strings and OSC payloads (URLs,
                    // titles, hyperlinks). The grapheme/width tracking lives below
                    // and only fires on visible codepoints, so the escape body bytes
                    // don't need per-byte processing here.
                    if (saw_csi) {
                        // CSI final byte is in [0x40, 0x7E].
                        const sub = input[j..idx];
                        if (scanLaneInRange(u16, 0x40, 0x7E, sub)) |t| {
                            saw_1b = false;
                            saw_csi = false;
                            j += t + 1;
                            continue;
                        }
                        // Terminator not in this ASCII run — stay in CSI state and
                        // advance to end. The next outer iteration (or non-ASCII
                        // codepoint handler) will continue parsing.
                        break;
                    }
                    if (saw_osc) {
                        // OSC payload terminates at BEL (0x07) or ESC + '\\' (ST).
                        // SIMD scan for either ESC or BEL — for ESC we then peek
                        // the next byte to see if it's '\\'.
                        const sub = input[j..idx];
                        if (scanLaneAnyOf(u16, &.{ 0x07, 0x1b }, sub)) |t| {
                            const term = sub[t];
                            if (term == 0x07) {
                                saw_1b = false;
                                saw_osc = false;
                                j += t + 1;
                                continue;
                            }
                            // ESC found at offset t. Peek next byte for '\\' (ST).
                            if (j + t + 1 < idx and input[j + t + 1] == '\\') {
                                saw_1b = false;
                                saw_osc = false;
                                j += t + 2;
                                continue;
                            }
                            // Lone ESC inside OSC — skip it and keep scanning. The
                            // next outer iteration will SIMD-scan again from j+t+1.
                            j += t + 1;
                            continue;
                        }
                        // Terminator not in this ASCII run — stay in OSC state.
                        break;
                    }

                    // Per-byte path for everything else.
                    const cp: u32 = input[j];
                    j += 1;

                    if (saw_1b) {
                        if (cp == '[') {
                            saw_csi = true;
                            continue;
                        } else if (cp == ']') {
                            saw_osc = true;
                            continue;
                        } else if (cp == 0x1b) {
                            // Another ESC - this one starts a new potential sequence
                            // Keep saw_1b = true, don't add width (ESC is control char anyway)
                            continue;
                        }
                        len += visibleCodepointWidth(cp, ambiguousAsWide);
                        saw_1b = false;
                        continue;
                    }
                    if (!exclude_ansi_colors or cp != 0x1b) {
                        if (prev_visible) |prev_| {
                            const should_break = grapheme.graphemeBreak(prev_, cp, &break_state);
                            if (should_break) {
                                len += grapheme_state.width();
                                grapheme_state.reset(cp, ambiguousAsWide);
                            } else {
                                grapheme_state.add(cp, ambiguousAsWide);
                            }
                        } else {
                            grapheme_state.reset(cp, ambiguousAsWide);
                        }
                        prev_visible = cp;
                        continue;
                    }
                    saw_1b = true;
                    continue;
                }
                input = input[idx..];
            }
            if (input.len == 0) break;
            const replacement = utf16CodepointWithFFFD(input);
            defer input = input[replacement.len..];
            // Skip invalid sequences and lone surrogates (treat as zero-width)
            if (replacement.fail or replacement.is_lead) continue;
            const cp: u32 = @intCast(replacement.code_point);

            // Handle non-ASCII characters inside escape sequences
            if (saw_osc) {
                // In OSC sequence, look for BEL (0x07) or C1 ST (0x9C). The
                // 7-bit ST (ESC \) only uses ASCII chars and is handled above.
                // Non-ASCII chars inside OSC should not contribute to width.
                if (cp == 0x07 or cp == 0x9c) {
                    saw_1b = false;
                    saw_osc = false;
                }
                continue;
            }
            if (saw_csi) {
                // CSI sequences should only contain ASCII parameters and final bytes
                // Non-ASCII char ends the CSI sequence abnormally - don't count it
                saw_1b = false;
                saw_csi = false;
                continue;
            }
            if (saw_1b) {
                // ESC followed by non-ASCII - not a valid sequence start
                saw_1b = false;
                // Don't count this char as part of escape, treat normally below
            }

            if (prev_visible) |prev_| {
                const should_break = grapheme.graphemeBreak(prev_, cp, &break_state);
                if (should_break) {
                    len += grapheme_state.width();
                    grapheme_state.reset(cp, ambiguousAsWide);
                } else {
                    grapheme_state.add(cp, ambiguousAsWide);
                }
            } else {
                grapheme_state.reset(cp, ambiguousAsWide);
            }
            prev_visible = cp;
        }
        // Add width of final grapheme
        len += grapheme_state.width();
        return len;
    }

    pub const width = struct {
        pub fn latin1(input: []const u8, ambiguousAsWide: bool) usize {
            return visibleLatin1Width(input, ambiguousAsWide);
        }

        pub fn utf8(input: []const u8, ambiguousAsWide: bool) usize {
            return visibleUTF8WidthFn(input, visibleLatin1Width, ambiguousAsWide);
        }

        pub fn utf16(input: []const u16, ambiguousAsWide: bool) usize {
            return visibleUTF16WidthFn(input, false, ambiguousAsWide);
        }

        pub const exclude_ansi_colors = struct {
            pub fn latin1(input: []const u8, ambiguousAsWide: bool) usize {
                return visibleLatin1WidthExcludeANSIColors(input, ambiguousAsWide);
            }

            pub fn utf8(input: []const u8, ambiguousAsWide: bool) usize {
                return visibleUTF8WidthFn(input, visibleLatin1WidthExcludeANSIColors, ambiguousAsWide);
            }

            pub fn utf16(input: []const u16, ambiguousAsWide: bool) usize {
                return visibleUTF16WidthFn(input, true, ambiguousAsWide);
            }

            /// Byte index of the longest prefix of `input` whose visible
            /// width is <= `max_width`. ANSI escapes count as zero-width
            /// and are always included in the prefix. Never splits a
            /// multi-byte UTF-8 codepoint.
            pub fn utf8IndexAtWidth(input: []const u8, max_width: usize) usize {
                return utf8IndexAtWidthExcludeANSI(input, max_width);
            }
        };
    };

    fn utf8IndexAtWidthExcludeANSI(input_: []const u8, max_width: usize) usize {
        var input = input_;
        var w: usize = 0;
        while (strings.indexOfCharUsize(input, '\x1b')) |esc| {
            // Walk the visible run before ESC.
            const run_start = @intFromPtr(input.ptr) - @intFromPtr(input_.ptr);
            if (utf8WalkRun(input_, run_start, esc, max_width, &w)) |stop| return stop;
            input = input[esc..];
            // Same CSI/OSC skip as visibleLatin1WidthExcludeANSIColors.
            if (input.len < 2) return input_.len;
            if (input[1] == '[') {
                if (input.len < 3) return input_.len;
                input = input[2..];
                if (scanLaneInRange(u8, 0x40, 0x7E, input)) |t| {
                    input = input[t + 1 ..];
                } else return input_.len;
            } else if (input[1] == ']') {
                input = input[2..];
                while (scanLaneAnyOf(u8, &.{ 0x07, 0x9c, 0x1b }, input)) |t| {
                    const term = input[t];
                    if (term == 0x07 or term == 0x9c) {
                        input = input[t + 1 ..];
                        break;
                    }
                    if (t + 1 < input.len and input[t + 1] == '\\') {
                        input = input[t + 2 ..];
                        break;
                    }
                    input = input[t + 1 ..];
                } else input = input[input.len..];
            } else {
                input = input[1..];
            }
        }
        const run_start = @intFromPtr(input.ptr) - @intFromPtr(input_.ptr);
        if (utf8WalkRun(input_, run_start, input.len, max_width, &w)) |stop| return stop;
        return input_.len;
    }

    /// Walk `len` bytes of `input` starting at absolute offset `start`,
    /// accumulating visible width. Returns the absolute byte index at
    /// which adding the next codepoint would exceed `max_width`, or null
    /// if the whole run fits. Mirrors visibleUTF8WidthFn's decode loop.
    fn utf8WalkRun(input: []const u8, start: usize, len: usize, max_width: usize, w: *usize) ?usize {
        var bytes = input[start .. start + len];
        while (firstNonASCII(bytes)) |i| {
            // ASCII run: each printable char is width 1.
            var k: usize = 0;
            while (k < i) : (k += 1) {
                const cw = visibleLatin1WidthScalar(bytes[k]);
                if (w.* + cw > max_width) {
                    return (@intFromPtr(bytes.ptr) - @intFromPtr(input.ptr)) + k;
                }
                w.* += cw;
            }
            const this_chunk = bytes[i..];
            const byte = this_chunk[0];
            const skip = bun.strings.wtf8ByteSequenceLength(byte);
            const cp_bytes: [4]u8 = switch (@min(@as(usize, skip), this_chunk.len)) {
                inline 1, 2, 3, 4 => |cp_len| .{
                    byte,
                    if (comptime cp_len > 1) this_chunk[1] else 0,
                    if (comptime cp_len > 2) this_chunk[2] else 0,
                    if (comptime cp_len > 3) this_chunk[3] else 0,
                },
                else => unreachable,
            };
            const cp = if (skip > 1) decodeWTF8RuneTMultibyte(&cp_bytes, skip, u32, unicode_replacement) else unicode_replacement;
            const cw = visibleCodepointWidth(cp, false);
            if (w.* + cw > max_width) {
                return (@intFromPtr(bytes.ptr) - @intFromPtr(input.ptr)) + i;
            }
            w.* += cw;
            bytes = bytes[@min(i + skip, bytes.len)..];
        }
        var k: usize = 0;
        while (k < bytes.len) : (k += 1) {
            const cw = visibleLatin1WidthScalar(bytes[k]);
            if (w.* + cw > max_width) {
                return (@intFromPtr(bytes.ptr) - @intFromPtr(input.ptr)) + k;
            }
            w.* += cw;
        }
        return null;
    }
};

// C exports for wrapAnsi.cpp

/// Calculate visible width of UTF-8 string excluding ANSI escape codes
export fn Bun__visibleWidthExcludeANSI_utf8(ptr: [*]const u8, len: usize, ambiguous_as_wide: bool) usize {
    const input = ptr[0..len];
    return visible.width.exclude_ansi_colors.utf8(input, ambiguous_as_wide);
}

/// Calculate visible width of UTF-16 string excluding ANSI escape codes
export fn Bun__visibleWidthExcludeANSI_utf16(ptr: [*]const u16, len: usize, ambiguous_as_wide: bool) usize {
    const input = ptr[0..len];
    return visible.width.exclude_ansi_colors.utf16(input, ambiguous_as_wide);
}

/// Calculate visible width of Latin-1 string excluding ANSI escape codes
export fn Bun__visibleWidthExcludeANSI_latin1(ptr: [*]const u8, len: usize, ambiguous_as_wide: bool) usize {
    const input = ptr[0..len];
    return visible.width.exclude_ansi_colors.latin1(input, ambiguous_as_wide);
}

/// Calculate visible width of a single codepoint
export fn Bun__codepointWidth(cp: u32, ambiguous_as_wide: bool) u8 {
    return @intCast(visibleCodepointWidth(cp, ambiguous_as_wide));
}

/// Grapheme break detection for C++ callers.
/// Returns true if there should be a grapheme break between cp1 and cp2.
/// `state` is an opaque u8 that must be initialized to 0 and passed between calls.
export fn Bun__graphemeBreak(cp1: u32, cp2: u32, state_ptr: *u8) bool {
    var state: grapheme.BreakState = @fromBackingInt(@intCast(state_ptr.*));
    const result = grapheme.graphemeBreak(cp1, cp2, &state);
    state_ptr.* = @backingInt(state);
    return result;
}

/// Check whether a codepoint is an emoji-capable width base.
export fn Bun__isEmojiPresentation(cp: u32) bool {
    return cp >= 0x80 and unicode.get(cp).emoji;
}

const bun = @import("bun");
const std = @import("std");

const strings = bun.strings;
const decodeWTF8RuneTMultibyte = strings.decodeWTF8RuneTMultibyte;
const firstNonASCII = strings.firstNonASCII;
const firstNonASCII16 = strings.firstNonASCII16;
const grapheme = strings.grapheme;
const unicode = @import("unicode_data");
const u3_fast = strings.u3_fast;
const unicode_replacement = strings.unicode_replacement;
const utf16CodepointWithFFFD = strings.utf16CodepointWithFFFD;
