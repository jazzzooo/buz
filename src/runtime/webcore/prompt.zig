//! Implements prompt, alert, and confirm Web API

/// https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#dom-alert
fn alert(
    context: bun.bindgen.CallContext(AlertSchema),
    args: bun.bindgen.Args(AlertSchema),
) bun.JSError!void {
    _ = context;
    return runAlert(bun.current_runtime.io(), args);
}

fn runAlert(io: std.Io, args: bun.bindgen.Args(AlertSchema)) bun.JSError!void {
    var output = bun.Output.writer();
    const has_message = args.message != null;

    // 2. If the method was invoked with no arguments, then let message be the empty string; otherwise, let message be the method's first argument.
    if (has_message) {
        var state_buffer: [2048]u8 = undefined;
        var state: std.heap.BufferFirstAllocator = .init(&state_buffer, bun.default_allocator);
        const allocator = state.allocator();
        const message = try args.message.?.toUTF8(allocator);
        defer message.deinit();

        if (message.length() > 0) {
            // 3. Set message to the result of normalizing newlines given message.
            // *  We skip step 3 because they are already done in most terminals by default.

            // 4. Set message to the result of optionally truncating message.
            // *  We just don't do this because it's not necessary.

            // 5. Show message to the user, treating U+000A LF as a line break.
            output.writeAll(message.slice()) catch {
                // 1. If we cannot show simple dialogs for this, then return.
                return;
            };
        }
    }

    output.writeAll(if (has_message) " [Enter] " else "Alert [Enter] ") catch {
        // 1. If we cannot show simple dialogs for this, then return.
        return;
    };

    // 6. Invoke WebDriver BiDi user prompt opened with this, "alert", and message.
    // *  Not pertinent to use their complex system in a server context.
    bun.Output.flush();

    // 7. Optionally, pause while waiting for the user to acknowledge the message.
    var stdin = std.Io.File.stdin();
    var stdin_buf: [1]u8 = undefined;
    var stdin_reader = stdin.readerStreaming(io, &stdin_buf);
    const reader = &stdin_reader.interface;
    while (true) {
        const byte = reader.takeByte() catch break;
        if (byte == '\n') break;
    }

    // 8. Invoke WebDriver BiDi user prompt closed with this and true.
    // *  Again, not necessary in a server context.

}

fn confirm(
    context: bun.bindgen.CallContext(ConfirmSchema),
    args: bun.bindgen.Args(ConfirmSchema),
) bun.JSError!bool {
    _ = context;
    return runConfirm(bun.current_runtime.io(), args);
}

fn runConfirm(io: std.Io, args: bun.bindgen.Args(ConfirmSchema)) bun.JSError!bool {
    var output = bun.Output.writer();
    const has_message = args.message != null;

    if (has_message) {
        var state_buffer: [1024]u8 = undefined;
        var state: std.heap.BufferFirstAllocator = .init(&state_buffer, bun.default_allocator);
        const allocator = state.allocator();
        // 2. Set message to the result of normalizing newlines given message.
        // *  Not pertinent to a server runtime so we will just let the terminal handle this.

        // 3. Set message to the result of optionally truncating message.
        // *  Not necessary so we won't do it.
        const message = try args.message.?.toUTF8(allocator);
        defer message.deinit();

        output.writeAll(message.slice()) catch {
            // 1. If we cannot show simple dialogs for this, then return false.
            return false;
        };
    }

    // 4. Show message to the user, treating U+000A LF as a line break,
    //    and ask the user to respond with a positive or negative
    //    response.
    output.writeAll(if (has_message) " [y/N] " else "Confirm [y/N] ") catch {
        // 1. If we cannot show simple dialogs for this, then return false.
        return false;
    };

    // 5. Invoke WebDriver BiDi user prompt opened with this, "confirm", and message.
    // *  Not relevant in a server context.
    bun.Output.flush();

    // 6. Pause until the user responds either positively or negatively.
    var stdin = std.Io.File.stdin();
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = stdin.readerStreaming(io, &stdin_buf);
    const reader = &stdin_reader.interface;

    const first_byte = reader.takeByte() catch {
        return false;
    };

    // 7. Invoke WebDriver BiDi user prompt closed with this, and true if
    //    the user responded positively or false otherwise.
    // *  Not relevant in a server context.

    switch (first_byte) {
        '\n' => return false,
        '\r' => {
            const next_byte = reader.takeByte() catch {
                // They may have said yes, but the stdin is invalid.
                return false;
            };
            if (next_byte == '\n') {
                return false;
            }
        },
        'y', 'Y' => {
            const next_byte = reader.takeByte() catch {
                // They may have said yes, but the stdin is invalid.

                return false;
            };

            if (next_byte == '\n') {
                // 8. If the user responded positively, return true;
                //    otherwise, the user responded negatively: return false.
                return true;
            } else if (next_byte == '\r') {
                //Check Windows style
                const second_byte = reader.takeByte() catch {
                    return false;
                };
                if (second_byte == '\n') {
                    return true;
                }
            }
        },
        else => {},
    }

    while (reader.takeByte()) |b| {
        if (b == '\n' or b == '\r') break;
    } else |_| {}

    // 8. If the user responded positively, return true; otherwise, the user
    //    responded negatively: return false.
    return false;
}

pub const prompt = struct {
    /// Adapted from `std.io.Reader.readUntilDelimiterArrayList` to only append
    /// and assume capacity.
    pub fn readUntilDelimiterArrayListAppendAssumeCapacity(
        reader: anytype,
        array_list: *std.array_list.Managed(u8),
        delimiter: u8,
        max_size: usize,
    ) !void {
        while (true) {
            if (array_list.items.len == max_size) {
                return error.StreamTooLong;
            }

            const byte: u8 = try reader.takeByte();

            if (byte == delimiter) {
                return;
            }

            array_list.appendAssumeCapacity(byte);
        }
    }

    /// Adapted from `std.io.Reader.readUntilDelimiterArrayList` to always append
    /// and not resize.
    fn readUntilDelimiterArrayListInfinity(
        reader: anytype,
        array_list: *std.array_list.Managed(u8),
        delimiter: u8,
    ) !void {
        while (true) {
            const byte: u8 = try reader.takeByte();

            if (byte == delimiter) {
                return;
            }

            try array_list.append(byte);
        }
    }

    /// https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#dom-prompt
    pub fn call(
        _: bun.bindgen.CallContext(PromptSchema),
        args: bun.bindgen.Args(PromptSchema),
    ) bun.JSError!?bun.bindgen.DOMString {
        return run(args);
    }

    fn run(
        args: bun.bindgen.Args(PromptSchema),
    ) bun.JSError!?bun.bindgen.DOMString {
        var state_buffer: [2048]u8 = undefined;
        var state: std.heap.BufferFirstAllocator = .init(&state_buffer, bun.default_allocator);
        const allocator = state.allocator();
        var output = bun.Output.writer();
        const has_message = args.message != null;
        const has_default = args.default_value != null;
        // 4. Set default to the result of optionally truncating default.
        // *  We don't really need to do this.
        if (has_message) {
            // 2. Set message to the result of normalizing newlines given message.
            // *  Not pertinent to a server runtime so we will just let the terminal handle this.

            // 3. Set message to the result of optionally truncating message.
            // *  Not necessary so we won't do it.
            const message = try args.message.?.toUTF8(allocator);
            defer message.deinit();

            output.writeAll(message.slice()) catch {
                // 1. If we cannot show simple dialogs for this, then return null.
                return null;
            };
        }

        // 4. Set default to the result of optionally truncating default.

        // 5. Show message to the user, treating U+000A LF as a line break,
        //    and ask the user to either respond with a string value or
        //    abort. The response must be defaulted to the value given by
        //    default.
        output.writeAll(if (has_message) " " else "Prompt ") catch {
            // 1. If we cannot show simple dialogs for this, then return false.
            return null;
        };

        if (has_default) {
            const default_string = try args.default_value.?.toUTF8(allocator);
            defer default_string.deinit();

            output.print("[{s}] ", .{default_string.slice()}) catch {
                // 1. If we cannot show simple dialogs for this, then return false.
                return null;
            };
        }

        // 6. Invoke WebDriver BiDi user prompt opened with this, "prompt" and message.
        // *  Not relevant in a server context.
        bun.Output.flush();

        // unset `ENABLE_VIRTUAL_TERMINAL_INPUT` on windows. This prevents backspace from
        // deleting the entire line
        const original_mode: if (Environment.isWindows) ?bun.windows.DWORD else void = if (comptime Environment.isWindows)
            bun.windows.updateStdioModeFlags(.std_in, .{ .unset = c.ENABLE_VIRTUAL_TERMINAL_INPUT }) catch null;

        defer if (comptime Environment.isWindows) {
            if (original_mode) |mode| {
                _ = bun.c.SetConsoleMode(bun.FD.stdin().native(), mode);
            }
        };

        // 7. Pause while waiting for the user's response.
        const reader = bun.Output.buffered_stdin.reader();
        var second_byte: ?u8 = null;
        const first_byte = reader.takeByte() catch {
            // 8. Let result be null if the user aborts, or otherwise the string
            //    that the user responded with.
            return null;
        };

        if (first_byte == '\n') {
            // 8. Let result be null if the user aborts, or otherwise the string
            //    that the user responded with.
            return if (args.default_value) |value| value.toOwned() else null;
        } else if (first_byte == '\r') {
            const second = reader.takeByte() catch return null;
            second_byte = second;
            if (second == '\n') return if (args.default_value) |value| value.toOwned() else null;
        }

        var input = std.array_list.Managed(u8).initCapacity(allocator, 2048) catch {
            // 8. Let result be null if the user aborts, or otherwise the string
            //    that the user responded with.
            return null;
        };
        defer input.deinit();

        input.appendAssumeCapacity(first_byte);
        if (second_byte) |second| input.appendAssumeCapacity(second);

        // All of this code basically just first tries to load the input into a
        // buffer of size 2048. If that is too small, then increase the buffer
        // size to 4096. If that is too small, then just dynamically allocate
        // the rest.
        readUntilDelimiterArrayListAppendAssumeCapacity(reader, &input, '\n', 2048) catch |e| {
            if (e != error.StreamTooLong) {
                // 8. Let result be null if the user aborts, or otherwise the string
                //    that the user responded with.
                return null;
            }

            input.ensureTotalCapacity(4096) catch {
                // 8. Let result be null if the user aborts, or otherwise the string
                //    that the user responded with.
                return null;
            };

            readUntilDelimiterArrayListAppendAssumeCapacity(reader, &input, '\n', 4096) catch |e2| {
                if (e2 != error.StreamTooLong) {
                    // 8. Let result be null if the user aborts, or otherwise the string
                    //    that the user responded with.
                    return null;
                }

                readUntilDelimiterArrayListInfinity(reader, &input, '\n') catch {
                    // 8. Let result be null if the user aborts, or otherwise the string
                    //    that the user responded with.
                    return null;
                };
            };
        };

        if (input.items.len > 0 and input.items[input.items.len - 1] == '\r') {
            input.items.len -= 1;
        }

        if (comptime Environment.allow_assert) {
            bun.assert(input.items.len > 0);
            bun.assert(input.items[input.items.len - 1] != '\r');
        }

        // 8. Let result be null if the user aborts, or otherwise the string
        //    that the user responded with.
        // 9. Invoke WebDriver BiDi user prompt closed with this, false if
        //    result is null or true otherwise, and result.
        // *  Too complex for server context.

        // 9. Return result.
        return try bun.bindgen.DOMString.fromUTF8(input.items);
    }
};

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const c = bun.c;

const PromptBindings = bun.bindgen.Module("Prompt");
const AlertSchema = PromptBindings.function("alert");
const ConfirmSchema = PromptBindings.function("confirm");
const PromptSchema = PromptBindings.function("prompt");
const AlertBinding = bun.bindgen.Fn(AlertSchema, alert);
const ConfirmBinding = bun.bindgen.Fn(ConfirmSchema, confirm);
const PromptBinding = bun.bindgen.Fn(PromptSchema, prompt.call);

comptime {
    _ = AlertBinding;
    _ = ConfirmBinding;
    _ = PromptBinding;
}
