// https://github.com/tmux/tmux/blob/dae2868d1227b95fd076fb4a5efa6256c7245943/colour.c#L44-L55
pub const Ansi256 = struct {
    const q2c = [_]u32{ 0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff };

    fn sqdist(R: u32, G: u32, B: u32, r: u32, g: u32, b: u32) u32 {
        return ((R -% r) *% (R -% r) +% (G -% g) *% (G -% g) +% (B -% b) *% (B -% b));
    }

    fn to6Cube(v: u32) u32 {
        if (v < 48)
            return (0);
        if (v < 114)
            return (1);
        return ((v - 35) / 40);
    }

    fn get(r: u32, g: u32, b: u32) u32 {
        const qr = to6Cube(r);
        const cr = q2c[@intCast(qr)];
        const qg = to6Cube(g);
        const cg = q2c[@intCast(qg)];
        const qb = to6Cube(b);
        const cb = q2c[@intCast(qb)];

        if (cr == r and cg == g and cb == b) {
            return 16 +% (36 *% qr) +% (6 *% qg) +% qb;
        }

        const grey_avg = (r +% g +% b) / 3;
        const grey_idx = if (grey_avg > 238) 23 else (grey_avg -% 3) / 10;
        const grey = 8 +% (10 *% grey_idx);

        const d = sqdist(cr, cg, cb, r, g, b);
        const idx = if (sqdist(grey, grey, grey, r, g, b) < d) 232 +% grey_idx else 16 +% (36 *% qr) +% (6 *% qg) +% qb;
        return idx;
    }

    const table_256: [256]u8 = .{
        0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
        0,  4,  4,  4,  12, 12, 2,  6,  4,  4,  12, 12, 2,  2,  6,  4,
        12, 12, 2,  2,  2,  6,  12, 12, 10, 10, 10, 10, 14, 12, 10, 10,
        10, 10, 10, 14, 1,  5,  4,  4,  12, 12, 3,  8,  4,  4,  12, 12,
        2,  2,  6,  4,  12, 12, 2,  2,  2,  6,  12, 12, 10, 10, 10, 10,
        14, 12, 10, 10, 10, 10, 10, 14, 1,  1,  5,  4,  12, 12, 1,  1,
        5,  4,  12, 12, 3,  3,  8,  4,  12, 12, 2,  2,  2,  6,  12, 12,
        10, 10, 10, 10, 14, 12, 10, 10, 10, 10, 10, 14, 1,  1,  1,  5,
        12, 12, 1,  1,  1,  5,  12, 12, 1,  1,  1,  5,  12, 12, 3,  3,
        3,  7,  12, 12, 10, 10, 10, 10, 14, 12, 10, 10, 10, 10, 10, 14,
        9,  9,  9,  9,  13, 12, 9,  9,  9,  9,  13, 12, 9,  9,  9,  9,
        13, 12, 9,  9,  9,  9,  13, 12, 11, 11, 11, 11, 7,  12, 10, 10,
        10, 10, 10, 14, 9,  9,  9,  9,  9,  13, 9,  9,  9,  9,  9,  13,
        9,  9,  9,  9,  9,  13, 9,  9,  9,  9,  9,  13, 9,  9,  9,  9,
        9,  13, 11, 11, 11, 11, 11, 15, 0,  0,  0,  0,  0,  0,  8,  8,
        8,  8,  8,  8,  7,  7,  7,  7,  7,  7,  15, 15, 15, 15, 15, 15,
    };

    pub fn get16(r: u32, g: u32, b: u32) u8 {
        const val = get(r, g, b);
        return table_256[val & 0xff];
    }

    pub const Buffer = [24]u8;

    pub fn from(rgba: RGBA, buf: *Buffer) []u8 {
        const val = get(rgba.red, rgba.green, rgba.blue);
        // 0x1b is the escape character
        buf[0] = 0x1b;
        buf[1] = '[';
        buf[2] = '3';
        buf[3] = '8';
        buf[4] = ';';
        buf[5] = '5';
        buf[6] = ';';
        const extra = std.fmt.bufPrint(buf[7..], "{d}m", .{val}) catch unreachable;
        return buf[0 .. 7 + extra.len];
    }
};

pub fn jsFunctionColor(
    context: bun.bindgen.CallContext(ColorSchema),
    args: bun.bindgen.Args(ColorSchema),
) bun.bindgen.CallError(ColorSchema)!ColorResult {
    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    var stack_fallback_buffer: [4096]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, arena.allocator());
    const allocator = stack_fallback.allocator();

    const unresolved_format: ColorFormat = args.format orelse .css;
    var input = bun.String.Slice.empty;
    defer input.deinit();

    var parsed_color: css.CssColor.ParseResult = switch (args.input) {
        .number => |number| brk: {
            const Packed = packed struct(u32) {
                blue: u8,
                green: u8,
                red: u8,
                alpha: u8,
            };
            const int: u32 = @truncate(@abs(@mod(number, std.math.maxInt(u32))));
            const rgba: Packed = @bitCast(int);

            break :brk .{ .result = css.CssColor{ .rgba = .{
                .alpha = if (int <= 0xffffff) 255 else rgba.alpha,
                .red = rgba.red,
                .green = rgba.green,
                .blue = rgba.blue,
            } } };
        },
        .components => |components| brk: {
            switch (components.len()) {
                3 => {
                    break :brk .{ .result = css.CssColor{ .rgba = .{
                        .alpha = 255,
                        .red = components.at(0).?,
                        .green = components.at(1).?,
                        .blue = components.at(2).?,
                    } } };
                },
                4 => {
                    break :brk .{ .result = css.CssColor{ .rgba = .{
                        .alpha = components.at(3).?,
                        .red = components.at(0).?,
                        .green = components.at(1).?,
                        .blue = components.at(2).?,
                    } } };
                },
                else => return context.fail(.invalid_component_count, {}),
            }
        },
        .object => |object| brk: {
            const alpha: u8 = if (object.alpha) |value|
                if (std.math.isNan(value)) 255 else @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0)
            else
                255;
            break :brk .{
                .result = css.CssColor{
                    .rgba = .{
                        .alpha = alpha,
                        .red = object.red,
                        .green = object.green,
                        .blue = object.blue,
                    },
                },
            };
        },
        .string => |string_value| brk: {
            input = try string_value.toUTF8(bun.default_allocator);

            var parser_input = css.ParserInput.new(allocator, input.slice());
            var parser = css.Parser.new(&parser_input, null, .{}, null);
            break :brk css.CssColor.parse(&parser);
        },
    };

    switch (parsed_color) {
        .err => return null,
        .result => |*result| {
            const format: ColorFormat = if (unresolved_format == .ansi) switch (bun.Output.Source.colorDepth()) {
                // No color terminal, therefore return an empty string
                .none => return ColorValue{ .text = bun.bindgen.DOMString.empty() },
                .@"16" => .ansi_16,
                .@"16m" => .ansi_16m,
                .@"256" => .ansi_256,
            } else unresolved_format;

            formatted: {
                const str = color: {
                    switch (format) {
                        // resolved above.
                        .ansi => unreachable,

                        // Use the CSS printer.
                        .css => break :formatted,

                        .number,
                        .rgb,
                        .rgba,
                        .hex,
                        .uppercase_hex,
                        .ansi_16,
                        .ansi_16m,
                        .ansi_256,
                        .object_rgba,
                        .object_rgb,
                        .array_rgba,
                        .array_rgb,
                        => |tag| {
                            const srgba = switch (result.*) {
                                .float => |float| switch (float.*) {
                                    .rgb => |rgb| rgb,
                                    inline else => |*val| val.into(.SRGB),
                                },
                                .rgba => |*rgba| rgba.into(.SRGB),
                                .lab => |lab| switch (lab.*) {
                                    inline else => |entry| entry.into(.SRGB),
                                },
                                else => break :formatted,
                            };
                            const rgba = srgba.into(.RGBA);
                            switch (tag) {
                                .object_rgba => return ColorValue{ .rgba = .{
                                    .r = rgba.red,
                                    .g = rgba.green,
                                    .b = rgba.blue,
                                    .a = rgba.alphaF32(),
                                } },
                                .object_rgb => return ColorValue{ .rgb = .{
                                    .r = rgba.red,
                                    .g = rgba.green,
                                    .b = rgba.blue,
                                } },
                                .array_rgb => {
                                    const components = [_]u8{ rgba.red, rgba.green, rgba.blue };
                                    return ColorValue{ .components = try ColorComponents.fromOwnedSlice(&components) };
                                },
                                .array_rgba => {
                                    const components = [_]u8{ rgba.red, rgba.green, rgba.blue, rgba.alpha };
                                    return ColorValue{ .components = try ColorComponents.fromOwnedSlice(&components) };
                                },
                                .number => {
                                    var int: u32 = 0;
                                    int |= @as(u32, rgba.red) << 16;
                                    int |= @as(u32, rgba.green) << 8;
                                    int |= @as(u32, rgba.blue);
                                    return ColorValue{ .number = int };
                                },
                                .hex => {
                                    break :color bun.String.createFormat("#{f}{f}{f}", .{ bun.fmt.hexIntLower(rgba.red), bun.fmt.hexIntLower(rgba.green), bun.fmt.hexIntLower(rgba.blue) });
                                },
                                .uppercase_hex => {
                                    break :color bun.String.createFormat("#{f}{f}{f}", .{ bun.fmt.hexIntUpper(rgba.red), bun.fmt.hexIntUpper(rgba.green), bun.fmt.hexIntUpper(rgba.blue) });
                                },
                                .rgb => {
                                    break :color bun.String.createFormat("rgb({d}, {d}, {d})", .{ rgba.red, rgba.green, rgba.blue });
                                },
                                .rgba => {
                                    break :color bun.String.createFormat("rgba({d}, {d}, {d}, {d})", .{ rgba.red, rgba.green, rgba.blue, rgba.alphaF32() });
                                },
                                .ansi_16 => {
                                    // 16-color ansi foreground: palette 0-7 is SGR 30-37, bright 8-15 is SGR 90-97
                                    const idx: u32 = Ansi256.get16(rgba.red, rgba.green, rgba.blue);
                                    const sgr = if (idx < 8) 30 + idx else 82 + idx;
                                    break :color bun.String.createFormat("\x1b[{d}m", .{sgr});
                                },
                                .ansi_16m => {
                                    // true color ansi
                                    var buf: [48]u8 = undefined;
                                    // 0x1b is the escape character
                                    buf[0] = 0x1b;
                                    buf[1] = '[';
                                    buf[2] = '3';
                                    buf[3] = '8';
                                    buf[4] = ';';
                                    buf[5] = '2';
                                    buf[6] = ';';
                                    const additional = std.fmt.bufPrint(buf[7..], "{d};{d};{d}m", .{
                                        rgba.red,
                                        rgba.green,
                                        rgba.blue,
                                    }) catch unreachable;

                                    break :color bun.String.cloneLatin1(buf[0 .. 7 + additional.len]);
                                },
                                .ansi_256 => {
                                    // ANSI escape sequence
                                    var buf: Ansi256.Buffer = undefined;
                                    const val = Ansi256.from(rgba, &buf);
                                    break :color bun.String.cloneLatin1(val);
                                },
                                else => unreachable,
                            }
                        },

                        .hsl => {
                            const hsl = switch (result.*) {
                                .float => |float| brk: {
                                    switch (float.*) {
                                        .hsl => |hsl| break :brk hsl,
                                        inline else => |*val| break :brk val.into(.HSL),
                                    }
                                },
                                .rgba => |*rgba| rgba.into(.HSL),
                                .lab => |lab| switch (lab.*) {
                                    inline else => |entry| entry.into(.HSL),
                                },
                                else => break :formatted,
                            };

                            break :color bun.String.createFormat("hsl({d}, {d}, {d})", .{ hsl.h, hsl.s, hsl.l });
                        },
                        .lab => {
                            const lab = switch (result.*) {
                                .float => |float| switch (float.*) {
                                    inline else => |*val| val.into(.LAB),
                                },
                                .lab => |lab| switch (lab.*) {
                                    .lab => |lab_| lab_,
                                    inline else => |entry| entry.into(.LAB),
                                },
                                .rgba => |*rgba| rgba.into(.LAB),
                                else => break :formatted,
                            };

                            break :color bun.String.createFormat("lab({d}, {d}, {d})", .{ lab.l, lab.a, lab.b });
                        },
                    }
                } catch return error.OutOfMemory;

                return ColorValue{ .text = try bun.bindgen.DOMString.fromBunString(str) };
            }

            // Fallback to CSS string output
            var dest = std.Io.Writer.Allocating.init(allocator);
            const writer = &dest.writer;

            const symbols = bun.ast.Symbol.Map{};
            var printer = css.Printer.new(
                allocator,
                std.array_list.Managed(u8).init(allocator),
                writer,
                css.PrinterOptions.default(),
                null,
                null,
                &symbols,
            );

            result.toCss(&printer) catch return error.OutOfMemory;

            return ColorValue{ .text = try bun.bindgen.DOMString.fromUTF8(dest.written()) };
        },
    }
}

const std = @import("std");

const color = @import("../css/values/color.zig");
const HSL = color.HSL;
const LAB = color.LAB;
const RGBA = color.RGBA;
const SRGB = color.SRGB;

const bun = @import("bun");
const css = bun.css;

const ColorSchema = bun.bindgen.Module("BunObject").function("color");
const ColorFormat = std.meta.Child(@FieldType(bun.bindgen.Args(ColorSchema), "format"));
const ColorResult = bun.bindgen.Return(ColorSchema);
const ColorValue = @typeInfo(ColorResult).optional.child;
const ColorComponents = @FieldType(ColorValue, "components");
const ColorBinding = bun.bindgen.Fn(ColorSchema, jsFunctionColor);

comptime {
    _ = ColorBinding;
}
