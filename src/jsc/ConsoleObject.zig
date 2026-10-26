const BindingEscape = bun.bindgen.Escape(@This());
const ConsoleObject = @This();

/// Default depth for console.log object inspection
/// Only --console-depth CLI flag and console.depth bunfig option should modify this
const DEFAULT_CONSOLE_LOG_DEPTH: u16 = 2;

const Counter = std.AutoHashMapUnmanaged(u64, u32);

stderr_buffer: [4096]u8,
stdout_buffer: [4096]u8,

error_writer_backing: bun.sys.File.QuietWriter,
writer_backing: bun.sys.File.QuietWriter,
error_writer: *std.Io.Writer,
writer: *std.Io.Writer,

default_indent: u16 = 0,

counts: Counter = .{},

pub fn format(_: @This(), comptime _: []const u8, _: anytype, _: anytype) !void {}

pub fn init(out: *ConsoleObject, error_writer: Output.Source.StreamType, writer: Output.Source.StreamType) void {
    out.* = .{
        .stderr_buffer = undefined,
        .stdout_buffer = undefined,

        .error_writer_backing = undefined,
        .writer_backing = undefined,

        .error_writer = undefined,
        .writer = undefined,
    };

    out.error_writer_backing = error_writer.quietBufferedWriter(&out.stderr_buffer);
    out.writer_backing = writer.quietBufferedWriter(&out.stdout_buffer);

    out.error_writer = &out.error_writer_backing.interface;
    out.writer = &out.writer_backing.interface;
}

pub const MessageLevel = enum(u32) {
    Log = 0,
    Warning = 1,
    Error = 2,
    Debug = 3,
    Info = 4,
    _,
};

pub const MessageType = enum(u32) {
    Log = 0,
    Dir = 1,
    DirXML = 2,
    Table = 3,
    Trace = 4,
    StartGroup = 5,
    StartGroupCollapsed = 6,
    EndGroup = 7,
    Clear = 8,
    Assert = 9,
    Timing = 10,
    Profile = 11,
    ProfileEnd = 12,
    Image = 13,
    _,
};

var stderr_mutex: std.Io.Mutex = .init;
var stdout_mutex: std.Io.Mutex = .init;

threadlocal var stderr_lock_count: u16 = 0;
threadlocal var stdout_lock_count: u16 = 0;

/// https://console.spec.whatwg.org/#formatter
pub fn messageWithTypeAndLevel(
    message_type: MessageType,
    level: MessageLevel,
    global: *JSGlobalObject,
    vals: []const JSValue,
) void {
    messageWithTypeAndLevel_(message_type, level, global, vals) catch |err| bun.jsc.voidFromJSError(err, global);
}
fn messageWithTypeAndLevel_(
    message_type: MessageType,
    level: MessageLevel,
    global: *JSGlobalObject,
    vals: []const JSValue,
) bun.JSError!void {
    const vm = global.bunVM();
    const io = vm.io;
    var console = vm.console;
    defer console.default_indent +|= @as(u16, @intFromBool(message_type == .StartGroup));

    if (message_type == .StartGroup and vals.len == 0) {
        // undefined is printed if passed explicitly.
        return;
    }

    if (message_type == .EndGroup) {
        console.default_indent -|= 1;
        return;
    }

    // Lock/unlock a mutex incase two JS threads are console.log'ing at the same time
    // We do this the slightly annoying way to avoid assigning a pointer
    if (level == .Warning or level == .Error or message_type == .Assert) {
        if (stderr_lock_count == 0) {
            stderr_mutex.lockUncancelable(io);
        }

        stderr_lock_count += 1;
    } else {
        if (stdout_lock_count == 0) {
            stdout_mutex.lockUncancelable(io);
        }

        stdout_lock_count += 1;
    }

    defer {
        if (level == .Warning or level == .Error or message_type == .Assert) {
            stderr_lock_count -= 1;

            if (stderr_lock_count == 0) {
                stderr_mutex.unlock(io);
            }
        } else {
            stdout_lock_count -= 1;

            if (stdout_lock_count == 0) {
                stdout_mutex.unlock(io);
            }
        }
    }

    if (message_type == .Clear) {
        Output.resetTerminal();
        return;
    }

    if (message_type == .Assert and vals.len == 0) {
        const text = if (Output.enable_ansi_colors_stderr)
            Output.prettyFmt("<r><red>Assertion failed<r>\n", true)
        else
            "Assertion failed\n";
        console.error_writer.writeAll(text) catch {};
        console.error_writer.flush() catch {};
        return;
    }

    const enable_colors = if (level == .Warning or level == .Error)
        Output.enable_ansi_colors_stderr
    else
        Output.enable_ansi_colors_stdout;

    const writer = if (level == .Warning or level == .Error)
        console.error_writer
    else
        console.writer;
    const Writer = @TypeOf(writer);

    if (bun.jsc.Jest.Jest.runner) |runner| {
        runner.bun_test_root.onBeforePrint();
    }

    var print_length = vals.len;
    // Get console depth from CLI options or bunfig, fallback to default
    const cli_context = CLI.get();
    const console_depth = cli_context.runtime_options.console_depth orelse DEFAULT_CONSOLE_LOG_DEPTH;

    var print_options: FormatOptions = .{
        .enable_colors = enable_colors,
        .add_newline = true,
        .flush = true,
        .default_indent = console.default_indent,
        .max_depth = console_depth,
        .error_display_level = switch (level) {
            .Error => .full,
            else => .normal,
            .Warning => .warn,
        },
    };

    if (message_type == .Table and vals.len >= 1) {
        // if value is not an object/array/iterable, don't print a table and just print it
        var tabular_data = vals[0];
        if (tabular_data.isObject()) {
            const properties: ?JSValue = if (vals.len >= 2 and vals[1].jsType().isArray()) vals[1] else null;
            var table_printer = try TablePrinter.init(
                global,
                level,
                tabular_data,
                properties,
            );
            defer table_printer.value_formatter.deinit();
            table_printer.value_formatter.indent += console.default_indent;

            switch (enable_colors) {
                inline else => |colors| table_printer.printTable(Writer, writer, colors) catch |err| switch (err) {
                    error.WriteFailed => return,
                    else => |failure| return failure,
                },
            }
            writer.flush() catch {};
            return;
        }
    }

    if (message_type == .Dir and vals.len >= 2) {
        print_length = 1;
        var opts = vals[1];
        if (opts.isObject()) {
            if (try opts.get("depth")) |depth_prop| {
                if (depth_prop.isInt32() or depth_prop.isNumber() or depth_prop.isBigInt())
                    print_options.max_depth = depth_prop.toU16()
                else if (depth_prop.isNull())
                    print_options.max_depth = std.math.maxInt(u16);
            }
            if (try opts.get("colors")) |colors_prop| {
                if (colors_prop.isBoolean())
                    print_options.enable_colors = colors_prop.toBoolean();
            }
        }
    }

    if (print_length > 0)
        format2(
            level,
            global,
            vals.ptr,
            print_length,
            writer,
            print_options,
        ) catch |err| switch (err) {
            error.WriteFailed => return,
            else => |failure| return failure,
        }
    else if (message_type == .Log) {
        _ = console.writer.write("\n") catch 0;
        console.writer.flush() catch {};
    } else if (message_type != .Trace)
        writer.writeAll("undefined\n") catch {};

    if (message_type == .Trace) {
        try writeTrace(Writer, writer, global);
        writer.flush() catch {};
    }
}

pub const TablePrinter = struct {
    const Column = struct {
        name: String,
        width: u32 = 1,
    };

    const RowKey = union(@This().Type) {
        str: String,
        num: u32,

        const Type = enum { str, num };
    };

    const PADDING = 1;

    globalObject: *JSGlobalObject,
    level: MessageLevel,
    value_formatter: ConsoleObject.Formatter,

    tabular_data: JSValue,
    properties: ?JSValue,

    is_iterable: bool,
    jstype: JSValue.JSType,

    /// width of the "Values" column.
    /// This column is not appended to "columns" from the start, because it needs to be the last column.
    values_col_width: ?u32 = null,

    values_col_idx: usize = std.math.maxInt(usize),

    pub fn init(
        globalObject: *JSGlobalObject,
        level: MessageLevel,
        tabular_data: JSValue,
        properties: ?JSValue,
    ) bun.JSError!TablePrinter {
        return TablePrinter{
            .level = level,
            .globalObject = globalObject,
            .tabular_data = tabular_data,
            .properties = properties,
            .is_iterable = try tabular_data.isIterable(),
            .jstype = tabular_data.jsType(),
            .value_formatter = ConsoleObject.Formatter{
                .remaining_values = &[_]JSValue{},
                .globalThis = globalObject,
                .ordered_properties = false,
                .quote_strings = false,
                .single_line = true,
                .max_depth = 5,
                .can_throw_stack_overflow = true,
                .stack_check = bun.StackCheck.init(),
            },
        };
    }

    const VisibleCharacterCounter = struct {
        width: *usize = undefined,
        interface: std.Io.Writer,

        pub fn init(width: *usize, buffer: []u8) VisibleCharacterCounter {
            return .{
                .width = width,
                .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
            };
        }

        fn countBytes(this: *VisibleCharacterCounter, bytes: []const u8) void {
            this.width.* += strings.visible.width.exclude_ansi_colors.utf8(bytes, false);
        }

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const this: *VisibleCharacterCounter = @alignCast(@fieldParentPtr("interface", writer));
            this.countBytes(writer.buffered());
            writer.end = 0;
            var consumed: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                this.countBytes(bytes);
                consumed += bytes.len;
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| {
                this.countBytes(pattern);
                consumed += pattern.len;
            }
            return consumed;
        }
    };

    fn getWidthForValue(this: *TablePrinter, value: JSValue) bun.JSError!u32 {
        var width: usize = 0;
        var discard_buf: [512]u8 = undefined; // using a buffer decreases vtable calls but requires unnecessary memcpys. is it faster or slower?
        var counter = VisibleCharacterCounter.init(&width, &discard_buf);
        var value_formatter = this.value_formatter;

        const tag = try ConsoleObject.Formatter.Tag.get(value, this.globalObject);
        value_formatter.quote_strings = !(tag.tag == .String or tag.tag == .StringPossiblyFormatted);
        value_formatter.format(
            tag,
            *std.Io.Writer,
            &counter.interface,
            value,
            this.globalObject,
            false,
        ) catch {}; // TODO:

        counter.interface.flush() catch |e| switch (e) {
            error.WriteFailed => if (Environment.ci_assert) bun.assert(false), // VisibleCharacterCounter write cannot fail
        };

        return @truncate(width);
    }

    /// Update the sizes of the columns for the values of a given row, and create any additional columns as needed
    fn updateColumnsForRow(this: *TablePrinter, columns: *std.array_list.Managed(Column), row_key: RowKey, row_value: JSValue) bun.JSError!void {
        // update size of "(index)" column
        const row_key_len: u32 = switch (row_key) {
            .str => |value| @intCast(value.visibleWidthExcludeANSIColors(false)),
            .num => |value| @truncate(bun.fmt.fastDigitCount(value)),
        };
        columns.items[0].width = @max(columns.items[0].width, row_key_len);

        // special handling for Map: column with idx=1 is "Keys"
        if (this.jstype.isMap()) {
            const entry_key = try row_value.getIndex(0);
            const entry_value = try row_value.getIndex(1);
            columns.items[1].width = @max(columns.items[1].width, try this.getWidthForValue(entry_key));
            this.values_col_width = @max(this.values_col_width orelse 0, try this.getWidthForValue(entry_value));
            return;
        }

        if (row_value.isObject()) {
            // object ->
            //  - if "properties" arg was provided: iterate the already-created columns (except for the 0-th which is the index)
            //  - otherwise: iterate the object properties, and create the columns on-demand
            if (!(this.properties == null)) {
                for (columns.items[1..]) |*column| {
                    if (try row_value.getOwn(column.name)) |value| {
                        column.width = @max(column.width, try this.getWidthForValue(value));
                    }
                }
            } else {
                const property_scope = row_value;
                var row_root = try row_value.toRoot();
                defer row_root.deinit();
                var cols_iter = try jsc.JSPropertyIterator(.{
                    .skip_empty_name = false,
                }).init(&property_scope, &row_root);
                defer cols_iter.deinit();

                while (try cols_iter.next(&property_scope)) |next_entry| {
                    var entry = next_entry;
                    const col_key = entry.name.takeBunString();
                    defer col_key.deref();

                    // find or create the column for the property
                    const column: *Column = brk: {
                        for (columns.items[1..]) |*col| {
                            if (col.name.eql(col_key)) {
                                break :brk col;
                            }
                        }

                        col_key.ref();
                        errdefer col_key.deref();

                        try columns.append(.{ .name = col_key });

                        break :brk &columns.items[columns.items.len - 1];
                    };

                    column.width = @max(column.width, try this.getWidthForValue(entry.value.operand(&property_scope)));
                }
            }
        } else if ((this.properties == null)) {
            // not object -> the value will go to the special "Values" column
            this.values_col_width = @max(this.values_col_width orelse 1, try this.getWidthForValue(row_value));
        }
    }

    fn writeStringNTimes(comptime Writer: type, writer: Writer, comptime str: []const u8, n: usize) !void {
        if (comptime str.len == 1) {
            try writer.splatByteAll(str[0], n);
            return;
        }

        for (0..n) |_| {
            try writer.writeAll(str);
        }
    }

    fn printRow(
        this: *TablePrinter,
        comptime Writer: type,
        writer: Writer,
        comptime enable_ansi_colors: bool,
        columns: *std.array_list.Managed(Column),
        row_key: RowKey,
        row_value: JSValue,
    ) !void {
        try writer.writeAll("│");
        {
            const len: u32 = switch (row_key) {
                .str => |value| @truncate(value.visibleWidthExcludeANSIColors(false)),
                .num => |value| @truncate(bun.fmt.fastDigitCount(value)),
            };
            const needed = columns.items[0].width -| len;

            // Right-align the number column
            try writer.splatByteAll(' ', needed + PADDING);
            switch (row_key) {
                .str => |value| try writer.print("{f}", .{value}),
                .num => |value| try writer.print("{d}", .{value}),
            }
            try writer.splatByteAll(' ', PADDING);
        }

        for (1..columns.items.len) |col_idx| {
            const col = columns.items[col_idx];

            try writer.writeAll("│");

            var maybe_value: ?JSValue = null;
            if (col_idx == 1 and this.jstype.isMap()) { // is the "Keys" column, when iterating a Map?
                maybe_value = try row_value.getIndex(0);
            } else if (col_idx == this.values_col_idx) { // is the "Values" column?
                if (this.jstype.isMap()) {
                    maybe_value = try row_value.getIndex(1);
                } else if (!row_value.isObject()) {
                    maybe_value = row_value;
                }
            } else if (row_value.isObject()) {
                maybe_value = try row_value.getOwn(col.name);
            }

            if (maybe_value == null) {
                try writer.splatByteAll(' ', col.width + (PADDING * 2));
            } else {
                const value = maybe_value.?;
                const len: u32 = try this.getWidthForValue(value);
                const needed = col.width -| len;
                try writer.splatByteAll(' ', PADDING);
                const tag = try ConsoleObject.Formatter.Tag.get(value, this.globalObject);
                var value_formatter = this.value_formatter;
                this.value_formatter.map_node = null;
                defer value_formatter.deinit();

                value_formatter.quote_strings = !(tag.tag == .String or tag.tag == .StringPossiblyFormatted);

                try value_formatter.format(
                    tag,
                    Writer,
                    writer,
                    value,
                    this.globalObject,
                    enable_ansi_colors,
                );

                try writer.splatByteAll(' ', needed + PADDING);
            }
        }
        try writer.writeAll("│\n");
    }

    pub fn printTable(
        this: *TablePrinter,
        comptime Writer: type,
        writer: *std.Io.Writer,
        comptime enable_ansi_colors: bool,
    ) !void {
        const globalObject = this.globalObject;

        var stack_fallback_buffer: [16]Column = undefined;
        var stack_fallback: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack_fallback_buffer), this.globalObject.allocator());
        var columns = try std.array_list.Managed(Column).initCapacity(stack_fallback.allocator(), 16);
        defer {
            for (columns.items) |*col| {
                col.name.deref();
            }
            columns.deinit();
        }

        // create the first column " " which is always present
        columns.appendAssumeCapacity(.{
            .name = String.static(" "),
            .width = 1,
        });

        // special case for Map: create the special "Key" column at index 1
        if (this.jstype.isMap()) {
            columns.appendAssumeCapacity(.{
                .name = String.static("Key"),
            });
        }

        // if the "properties" arg was provided, pre-populate the columns
        if (!(this.properties == null)) {
            var properties_iter = try this.properties.?.arrayIterator();
            defer properties_iter.deinit();
            const scope = this.tabular_data;
            while (try properties_iter.next(&scope)) |value_result| {
                var name_result = try scope.engineIn("js_strings", "stringFromJS").call(.{ .value = value_result.operand(&scope) });
                const name = name_result.takeBunString();
                columns.append(.{ .name = name }) catch |err| {
                    name.deref();
                    return err;
                };
            }
        }

        // rows first pass - calculate the column widths
        {
            if (this.is_iterable) {
                var ctx_: struct { this: *TablePrinter, columns: *@TypeOf(columns), idx: u32 = 0, err: bool = false } = .{ .this = this, .columns = &columns };
                try this.tabular_data.forEach(&ctx_, struct {
                    fn callback(_: *jsc.VM, _: *JSGlobalObject, ctx: *@TypeOf(ctx_), value: JSValue) void {
                        updateColumnsForRow(ctx.this, ctx.columns, .{ .num = ctx.idx }, value) catch {
                            ctx.err = true;
                        };
                        ctx.idx += 1;
                    }
                }.callback);
                if (ctx_.err) return error.JSError;
            } else {
                const property_scope = this.tabular_data;
                const tabular_object = try property_scope.engineIn("js_value_conversions", "jsValueToObject").call(.{
                    .value = this.tabular_data,
                });
                var tabular_root = try tabular_object.eraseBrandToEngineRoot();
                defer tabular_root.deinit();
                var rows_iter = try jsc.JSPropertyIterator(.{
                    .skip_empty_name = false,
                }).init(&property_scope, &tabular_root);
                defer rows_iter.deinit();

                while (try rows_iter.next(&property_scope)) |next_entry| {
                    var entry = next_entry;
                    const row_key = entry.name.takeBunString();
                    defer row_key.deref();
                    try this.updateColumnsForRow(&columns, .{ .str = row_key }, entry.value.operand(&property_scope).asEngine());
                }
            }
        }

        // append the special "Values" column as the last one, if it is present
        if (this.values_col_width) |width| {
            this.values_col_idx = columns.items.len;
            try columns.append(.{
                .name = String.static("Values"),
                .width = width,
            });
        }

        // print the table header (border line + column names line + border line)
        {
            for (columns.items) |*col| {
                // also update the col width with the length of the column name itself
                col.width = @max(col.width, @as(u32, @intCast(col.name.visibleWidthExcludeANSIColors(false))));
            }

            try writer.writeAll("┌");
            for (columns.items, 0..) |*col, i| {
                if (i > 0) try writer.writeAll("┬");
                try writeStringNTimes(Writer, writer, "─", col.width + (PADDING * 2));
            }

            try writer.writeAll("┐\n│");

            for (columns.items, 0..) |col, i| {
                if (i > 0) try writer.writeAll("│");
                const len = col.name.visibleWidthExcludeANSIColors(false);
                const needed = col.width -| len;
                try writer.splatByteAll(' ', 1);
                if (comptime enable_ansi_colors) {
                    try writer.writeAll(Output.prettyFmt("<r><b>", true));
                }
                try writer.print("{f}", .{col.name});
                if (comptime enable_ansi_colors) {
                    try writer.writeAll(Output.prettyFmt("<r>", true));
                }
                try writer.splatByteAll(' ', needed + PADDING);
            }

            try writer.writeAll("│\n├");
            for (columns.items, 0..) |col, i| {
                if (i > 0) try writer.writeAll("┼");
                try writeStringNTimes(Writer, writer, "─", col.width + (PADDING * 2));
            }
            try writer.writeAll("┤\n");
        }

        // rows second pass - print the actual table rows
        {
            if (this.is_iterable) {
                var ctx_: struct { this: *TablePrinter, columns: *@TypeOf(columns), writer: Writer, idx: u32 = 0, err: bool = false } = .{ .this = this, .columns = &columns, .writer = writer };
                try this.tabular_data.forEach(&ctx_, struct {
                    fn callback(_: *jsc.VM, _: *JSGlobalObject, ctx: *@TypeOf(ctx_), value: JSValue) void {
                        printRow(ctx.this, Writer, ctx.writer, enable_ansi_colors, ctx.columns, .{ .num = ctx.idx }, value) catch {
                            ctx.err = true;
                        };
                        ctx.idx += 1;
                    }
                }.callback);
                if (ctx_.err) return error.JSError;
            } else {
                if (!this.tabular_data.isCell()) {
                    return globalObject.throwTypeError("tabular_data must be an object or array", .{});
                }
                const property_scope = this.tabular_data;
                const tabular_object = try property_scope.engineIn("js_value_conversions", "jsValueToObject").call(.{
                    .value = this.tabular_data,
                });
                var tabular_root = try tabular_object.eraseBrandToEngineRoot();
                defer tabular_root.deinit();
                var rows_iter = try jsc.JSPropertyIterator(.{
                    .skip_empty_name = false,
                }).init(&property_scope, &tabular_root);
                defer rows_iter.deinit();

                while (try rows_iter.next(&property_scope)) |entry_value| {
                    var entry = entry_value;
                    const row_key = entry.name.takeBunString();
                    defer row_key.deref();
                    try this.printRow(Writer, writer, enable_ansi_colors, &columns, .{ .str = row_key }, entry.value.operand(&property_scope).asEngine());
                }
            }
        }

        // print the table bottom border
        {
            try writer.writeAll("└");
            try writeStringNTimes(Writer, writer, "─", columns.items[0].width + (PADDING * 2));
            for (columns.items[1..]) |*column| {
                try writer.writeAll("┴");
                try writeStringNTimes(Writer, writer, "─", column.width + (PADDING * 2));
            }
            try writer.writeAll("┘\n");
        }
    }
};

pub fn writeTrace(comptime Writer: type, writer: Writer, global: *JSGlobalObject) bun.JSError!void {
    var vm = VirtualMachine.get();
    var diagnostic = jsc.Diagnostic.empty;
    defer diagnostic.deinit();

    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var message = try bun.bindgen.DOMString.fromUTF8("trace output");
    defer message.deinit();
    const err = try scope.engineIn("errors", "createError").call(.{ .message = message.operand() });
    try vm.remapDiagnostic(
        &diagnostic,
        &scope,
        err.operand(&scope).asEngine(),
        null,
        false,
    );

    if (Output.enable_ansi_colors_stderr)
        VirtualMachine.printStackTrace(
            Writer,
            writer,
            jsc.Diagnostic.trace(&diagnostic.value),
            true,
        ) catch {}
    else
        VirtualMachine.printStackTrace(
            Writer,
            writer,
            jsc.Diagnostic.trace(&diagnostic.value),
            false,
        ) catch {};
}

pub const FormatOptions = struct {
    enable_colors: bool,
    add_newline: bool,
    flush: bool,
    ordered_properties: bool = false,
    quote_strings: bool = false,
    max_depth: u16 = 2,
    single_line: bool = false,
    default_indent: u16 = 0,
    error_display_level: ErrorDisplayLevel = .full,
    pub const ErrorDisplayLevel = enum {
        normal,
        warn,
        full,

        const Formatter = struct {
            name: bun.TextView,
            level: ErrorDisplayLevel,
            enable_colors: bool,
            colon: Colon,
            pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                if (this.enable_colors) {
                    switch (this.level) {
                        .normal => try writer.writeAll(Output.prettyFmt("<r>", true)),
                        .warn => try writer.writeAll(Output.prettyFmt("<r><yellow>", true)),
                        .full => try writer.writeAll(Output.prettyFmt("<r><red>", true)),
                    }
                }

                if (!this.name.isEmpty()) {
                    try this.name.format(writer);
                } else if (this.level == .warn) {
                    try writer.writeAll("warn");
                } else {
                    try writer.writeAll("error");
                }

                if (this.colon == .exclude_colon) {
                    if (this.enable_colors) {
                        try writer.writeAll(Output.prettyFmt("<r>", true));
                    }
                    return;
                }

                if (this.enable_colors) {
                    try writer.writeAll(Output.prettyFmt("<r><d>:<r> ", true));
                } else {
                    try writer.writeAll(": ");
                }
            }
        };

        pub const Colon = enum { include_colon, exclude_colon };
        pub fn formatter(this: ErrorDisplayLevel, error_name: bun.TextView, enable_colors: bool, colon: Colon) ErrorDisplayLevel.Formatter {
            return .{
                .name = error_name,
                .level = this,
                .enable_colors = enable_colors,
                .colon = colon,
            };
        }
    };
};

pub const FormatError = bun.JSError || std.Io.Writer.Error;

pub fn format2(
    level: MessageLevel,
    global: *JSGlobalObject,
    vals: [*]const JSValue,
    len: usize,
    writer: *std.Io.Writer,
    options: FormatOptions,
) FormatError!void {
    if (len == 0) {
        if (options.add_newline) try writer.writeByte('\n');
        if (options.flush) try writer.flush();
        return;
    }

    var this_value = vals[0];
    var fmt = ConsoleObject.Formatter{
        .remaining_values = vals[0..len][1..],
        .globalThis = global,
        .ordered_properties = options.ordered_properties,
        .quote_strings = options.quote_strings,
        .max_depth = options.max_depth,
        .single_line = options.single_line,
        .indent = options.default_indent,
        .stack_check = bun.StackCheck.init(),
        .can_throw_stack_overflow = true,
        .error_display_level = options.error_display_level,
    };
    defer fmt.deinit();
    var tag = try ConsoleObject.Formatter.Tag.get(this_value, global);
    try fmt.writeIndent(*std.Io.Writer, writer);
    const color_error = options.enable_colors and level == .Error and (len > 1 or tag.tag == .String);
    if (color_error) try writer.writeAll(comptime Output.prettyFmt("<r><red>", true));

    while (true) {
        if (tag.tag == .String and fmt.remaining_values.len > 0) {
            tag.tag = .{ .StringPossiblyFormatted = {} };
        }
        if (options.enable_colors)
            try fmt.format(tag, *std.Io.Writer, writer, this_value, global, true)
        else
            try fmt.format(tag, *std.Io.Writer, writer, this_value, global, false);
        try checkFormatFailure(&fmt);
        if (fmt.remaining_values.len == 0) break;
        try writer.writeByte(' ');
        this_value = fmt.remaining_values[0];
        fmt.remaining_values = fmt.remaining_values[1..];
        tag = try ConsoleObject.Formatter.Tag.get(this_value, global);
    }

    if (color_error) try writer.writeAll(comptime Output.prettyFmt("<r>", true));
    if (options.add_newline) try writer.writeByte('\n');
    if (options.flush) try writer.flush();
}

fn checkFormatFailure(formatter: *const Formatter) FormatError!void {
    switch (formatter.globalThis.pendingExceptionKind()) {
        .none => {},
        .other => return error.JSError,
        .termination => return error.JSTerminated,
    }
    if (formatter.failed) return error.WriteFailed;
}

fn checkMemoryFormatFailure(formatter: *const Formatter) bun.JSError!void {
    checkFormatFailure(formatter) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |js_error| return js_error,
    };
}

const CustomFormattedObject = struct {
    function: JSValue,
    this: JSValue,
};

pub const Formatter = struct {
    globalThis: *JSGlobalObject,

    remaining_values: []const JSValue = &[_]JSValue{},
    map: Visited.Map = undefined,
    map_node: ?*Visited.Pool.Node = null,
    hide_native: bool = false,
    indent: u32 = 0,
    depth: u16 = 0,
    max_depth: u16 = 8,
    quote_strings: bool = false,
    quote_keys: bool = false,
    failed: bool = false,
    estimated_line_length: usize = 0,
    always_newline_scope: bool = false,
    single_line: bool = false,
    ordered_properties: bool = false,
    custom_formatted_object: ?CustomFormattedObject = null,
    disable_inspect_custom: bool = false,
    stack_check: ?bun.StackCheck = null,
    can_throw_stack_overflow: bool = false,
    error_display_level: FormatOptions.ErrorDisplayLevel = .full,
    /// If ArrayBuffer-like objects contain ascii text, the buffer is printed as a string.
    /// Set true in the error printer so that ShellError prints a more readable message.
    format_buffer_as_text: bool = false,

    fn recordWriteFailure(this: *Formatter) void {
        this.failed = true;
    }

    pub fn deinit(this: *Formatter) void {
        if (bun.take(&this.map_node)) |node| {
            node.data = this.map;
            if (node.data.capacity() > 512) {
                node.data.clearAndFree();
            } else {
                node.data.clearRetainingCapacity();
            }
            node.release();
        }
    }

    pub fn toFmt(this: *Formatter, value: JSValue) ZigFormatter {
        this.remaining_values = &.{};
        this.deinit();
        this.stack_check = null;
        return .{ .formatter = this, .value = value };
    }

    pub fn toScopedFmt(this: *Formatter, context: anytype, value: bun.bindgen.EngineValueView) ZigFormatter {
        return this.toFmt(value.operand(context));
    }

    pub fn goodTimeForANewLine(this: *@This()) bool {
        if (this.estimated_line_length > 80) {
            this.resetLine();
            return true;
        }
        return false;
    }

    pub fn resetLine(this: *@This()) void {
        this.estimated_line_length = this.indent * 2;
    }

    pub fn addForNewLine(this: *@This(), len: usize) void {
        this.estimated_line_length +|= len;
    }

    pub const ZigFormatter = struct {
        formatter: *ConsoleObject.Formatter,
        value: JSValue,

        pub const WriteError = error{UhOh};
        pub fn format(self: ZigFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            self.formatter.remaining_values = &[_]JSValue{self.value};
            defer {
                self.formatter.remaining_values = &[_]JSValue{};
            }
            self.formatter.format(
                Tag.get(self.value, self.formatter.globalThis) catch |e| return self.formatter.globalThis.formatErrorToWriterError(e),
                @TypeOf(writer),
                writer,
                self.value,
                self.formatter.globalThis,
                false,
            ) catch |e| return self.formatter.globalThis.formatErrorToWriterError(e);
            if (self.formatter.failed or self.formatter.globalThis.hasException()) return error.WriteFailed;
        }
    };

    // For detecting circular references
    pub const Visited = struct {
        const ObjectPool = @import("../collections/pool.zig").ObjectPool;
        pub const Map = std.AutoHashMap(jsc.JSValue, void);
        pub const Pool = ObjectPool(
            Map,
            struct {
                pub fn init(allocator: std.mem.Allocator) bun.OOM!Map {
                    return Map.init(allocator);
                }
            }.init,
            true,
            16,
        );
    };

    pub const Tag = enum {
        StringPossiblyFormatted,
        String,
        Undefined,
        Double,
        Integer,
        Null,
        Boolean,
        Array,
        Object,
        Function,
        Class,
        Error,
        TypedArray,
        Map,
        MapIterator,
        SetIterator,
        Set,
        BigInt,
        Symbol,

        CustomFormattedObject,

        GlobalObject,
        Private,
        Promise,

        JSON,
        toJSON,
        NativeCode,

        JSX,
        Event,

        GetterSetter,
        CustomGetterSetter,

        Proxy,
        RevokedProxy,

        pub fn isPrimitive(this: Tag) bool {
            return switch (this) {
                .String,
                .StringPossiblyFormatted,
                .Undefined,
                .Double,
                .Integer,
                .Null,
                .Boolean,
                .Symbol,
                .BigInt,
                => true,
                else => false,
            };
        }

        pub fn canHaveCircularReferences(tag: Tag) bool {
            return switch (tag) {
                .Function, .Array, .Object, .Map, .Set, .Error, .Class, .Event, .Private, .CustomFormattedObject, .toJSON => true,
                else => false,
            };
        }

        const Result = struct {
            tag: union(Tag) {
                StringPossiblyFormatted: void,
                String: void,
                Undefined: void,
                Double: void,
                Integer: void,
                Null: void,
                Boolean: void,
                Array: void,
                Object: void,
                Function: void,
                Class: void,
                Error: void,
                TypedArray: void,
                Map: void,
                MapIterator: void,
                SetIterator: void,
                Set: void,
                BigInt: void,
                Symbol: void,
                CustomFormattedObject: CustomFormattedObject,
                GlobalObject: void,
                Private: void,
                Promise: void,
                JSON: void,
                toJSON: void,
                NativeCode: void,
                JSX: void,
                Event: void,
                GetterSetter: void,
                CustomGetterSetter: void,
                Proxy: void,
                RevokedProxy: void,

                pub fn isPrimitive(this: @This()) bool {
                    return @as(Tag, this).isPrimitive();
                }

                pub fn tag(this: @This()) Tag {
                    return @as(Tag, this);
                }
            },
            cell: JSValue.JSType = JSValue.JSType.Cell,
        };

        pub fn get(value: JSValue, globalThis: *JSGlobalObject) bun.JSError!Result {
            return getAdvanced(value, globalThis, .{ .hide_global = false });
        }

        // It sounds silly to make this packed, but Tag.getAdvanced is extremely recursive.
        pub const Options = packed struct {
            hide_global: bool = false,
            disable_inspect_custom: bool = false,
        };

        pub fn getAdvanced(value: JSValue, globalThis: *JSGlobalObject, opts: Options) bun.JSError!Result {
            if (value.isUndefined()) return .{ .tag = .Undefined };
            if (value.isNull()) return .{ .tag = .Null };

            if (value.isInt32()) {
                return .{
                    .tag = .{ .Integer = {} },
                };
            } else if (value.isNumber()) {
                return .{
                    .tag = .{ .Double = {} },
                };
            } else if (value.isBoolean()) {
                return .{
                    .tag = .{ .Boolean = {} },
                };
            }

            if (!value.isCell())
                return .{
                    .tag = .{ .NativeCode = {} },
                };

            const js_type = value.jsType();

            if (js_type.isHidden()) return .{
                .tag = .{ .NativeCode = {} },
                .cell = js_type,
            };

            if (js_type == .Cell) {
                return .{
                    .tag = .{ .NativeCode = {} },
                    .cell = js_type,
                };
            }

            if (js_type.canGet() and js_type != .ProxyObject and !opts.disable_inspect_custom) {
                // Attempt to get custom formatter
                if (try value.fastGet(.inspectCustom)) |callback_value| {
                    if (callback_value.isCallable() and !try value.isConstructorPrototype()) {
                        return .{
                            .tag = .{
                                .CustomFormattedObject = .{
                                    .function = callback_value,
                                    .this = value,
                                },
                            },
                            .cell = js_type,
                        };
                    }
                }
            }

            if (js_type == .DOMWrapper or
                bun.api.Timer.TimeoutObject.Binding.isInstance(rawValue(value)) or
                bun.api.Timer.ImmediateObject.Binding.isInstance(rawValue(value)) or
                JestPrettyFormat.isAsymmetricMatcher(value))
            {
                return .{
                    .tag = .{ .Private = {} },
                    .cell = js_type,
                };
            }

            // If we check an Object has a method table and it does not
            // it will crash
            if (js_type != .Object and js_type != .ProxyObject and value.isCallable()) {
                if (value.isClass()) {
                    return .{
                        .tag = .{ .Class = {} },
                        .cell = js_type,
                    };
                }

                return .{
                    // TODO: we print InternalFunction as Object because we have a lot of
                    // callable namespaces and printing the contents of it is better than [Function: namespace]
                    // ideally, we would print [Function: namespace] { ... } on all functions, internal and js.
                    // what we'll do later is rid of .Function and .Class and handle the prefix in the .Object formatter
                    .tag = if (js_type == .InternalFunction) .Object else .Function,
                    .cell = js_type,
                };
            }

            if (js_type == .GlobalProxy) {
                if (!opts.hide_global) {
                    return Tag.get(
                        (try value.proxyTarget()).?,
                        globalThis,
                    );
                }
                return .{
                    .tag = .{ .GlobalObject = {} },
                    .cell = js_type,
                };
            }

            // Is this a react element?
            if (js_type.isObject() and js_type != .ProxyObject) {
                if (try value.getOwn("$$typeof")) |typeof_symbol| react: {
                    if (typeof_symbol.isUndefined()) break :react;
                    // "react.transitional.element" is React 19; "react.element" is React 18 and
                    // below - https://github.com/oven-sh/bun/issues/17223
                    if (try typeof_symbol.isSymbolFor("react.element") or
                        try typeof_symbol.isSymbolFor("react.transitional.element") or
                        try typeof_symbol.isSymbolFor("react.fragment"))
                    {
                        return .{ .tag = .{ .JSX = {} }, .cell = js_type };
                    }
                }
            }

            return .{
                .tag = switch (js_type) {
                    .ErrorInstance => .Error,
                    .NumberObject => .Double,
                    .DerivedArray, JSValue.JSType.Array, .DirectArguments, .ScopedArguments, .ClonedArguments => .Array,
                    .DerivedStringObject, JSValue.JSType.String, JSValue.JSType.StringObject => .String,
                    .RegExpObject => .String,
                    .Symbol => .Symbol,
                    .BooleanObject => .Boolean,
                    .JSFunction => .Function,
                    .WeakMap, JSValue.JSType.Map => .Map,
                    .MapIterator => .MapIterator,
                    .SetIterator => .SetIterator,
                    .WeakSet, JSValue.JSType.Set => .Set,
                    .JSDate => .JSON,
                    .JSPromise => .Promise,

                    .WrapForValidIterator,
                    .RegExpStringIterator,
                    .JSArrayIterator,
                    .Iterator,
                    .IteratorHelper,
                    .Object,
                    .FinalObject,
                    .ModuleNamespaceObject,
                    => .Object,

                    .ProxyObject => tag: {
                        const handler = (try value.getProxyInternalField(.handler)) orelse break :tag .RevokedProxy;
                        if (handler.isUndefinedOrNull()) {
                            break :tag .RevokedProxy;
                        }
                        break :tag .Proxy;
                    },

                    .GlobalObject => if (!opts.hide_global)
                        .Object
                    else
                        .GlobalObject,

                    .ArrayBuffer,
                    .Int8Array,
                    .Uint8Array,
                    .Uint8ClampedArray,
                    .Int16Array,
                    .Uint16Array,
                    .Int32Array,
                    .Uint32Array,
                    .Float16Array,
                    .Float32Array,
                    .Float64Array,
                    .BigInt64Array,
                    .BigUint64Array,
                    .DataView,
                    => .TypedArray,

                    .HeapBigInt => .BigInt,

                    // None of these should ever exist here
                    // But we're going to check anyway
                    .APIValueWrapper,
                    .NativeExecutable,
                    .ProgramExecutable,
                    .ModuleProgramExecutable,
                    .EvalExecutable,
                    .FunctionExecutable,
                    .UnlinkedFunctionExecutable,
                    .UnlinkedProgramCodeBlock,
                    .UnlinkedModuleProgramCodeBlock,
                    .UnlinkedEvalCodeBlock,
                    .UnlinkedFunctionCodeBlock,
                    .CodeBlock,
                    .JSCellButterfly,
                    .JSSourceCode,
                    .JSCallee,
                    .GlobalLexicalEnvironment,
                    .LexicalEnvironment,
                    .ModuleEnvironment,
                    .StrictEvalActivation,
                    .WithScope,
                    => .NativeCode,

                    .Event => .Event,

                    .GetterSetter => .GetterSetter,
                    .CustomGetterSetter => .CustomGetterSetter,

                    .JSAsJSONType => .toJSON,

                    else => .JSON,
                },
                .cell = js_type,
            };
        }
    };

    threadlocal var name_buf: [512]u8 = undefined;

    /// https://console.spec.whatwg.org/#formatter
    const PercentTag = enum {
        s, // s
        i, // i or d
        f, // f
        o, // o
        O, // O
        c, // c
        j, // j
    };

    fn writeWithFormatting(
        this: *ConsoleObject.Formatter,
        comptime Writer: type,
        writer_: Writer,
        comptime Slice: type,
        slice_: Slice,
        global: *JSGlobalObject,
        comptime enable_ansi_colors: bool,
    ) bun.JSError!void {
        var writer = WrappedWriter(Writer){
            .ctx = writer_,
            .failed = &this.failed,
            .estimated_line_length = &this.estimated_line_length,
        };
        var slice = slice_;
        var i: usize = 0;
        var len = slice.len;
        var hit_percent = false;
        while (i < len) : (i += 1) {
            if (this.failed) return;
            if (hit_percent) {
                i = 0;
                hit_percent = false;
            }

            switch (slice[i]) {
                '%' => {
                    i += 1;
                    if (i >= len)
                        break;

                    if (this.remaining_values.len == 0)
                        break;

                    const token: PercentTag = switch (slice[i]) {
                        's' => .s,
                        'f' => .f,
                        'o' => .o,
                        'O' => .O,
                        'd', 'i' => .i,
                        'c' => .c,
                        'j' => .j,
                        '%' => {
                            // print up to and including the first %
                            const end = slice[0..i];
                            writer.writeAll(end);
                            // then skip the second % so we dont hit it again
                            slice = slice[@min(slice.len, i + 1)..];
                            len = slice.len;
                            i = 0;
                            continue;
                        },
                        else => continue,
                    };

                    // Flush everything up to the %
                    const end = slice[0 .. i - 1];
                    writer.writeAll(end);
                    if (this.failed) return;
                    slice = slice[@min(slice.len, i + 1)..];
                    i = 0;
                    hit_percent = true;
                    len = slice.len;
                    const next_value = this.remaining_values[0];
                    this.remaining_values = this.remaining_values[1..];

                    // https://console.spec.whatwg.org/#formatter
                    const max_before_e_notation = 1000000000000000000000;
                    const min_before_e_notation = 0.000001;
                    switch (token) {
                        .s => try this.printAs(Tag.String, Writer, writer_, next_value, next_value.jsType(), enable_ansi_colors),
                        .i => {
                            // 1. If Type(current) is Symbol, let converted be NaN
                            // 2. Otherwise, let converted be the result of Call(%parseInt%, undefined, current, 10)
                            const int: i64 = brk: {
                                // This logic is convoluted because %parseInt% will coerce the argument to a string
                                // first. As an optimization, we can check if the argument is a number and
                                // skip such coercion.
                                if (next_value.isInt32()) {
                                    // Already an int, parseInt will parse to itself.
                                    break :brk next_value.asInt32();
                                }

                                if (next_value.isNumber() or !next_value.isSymbol()) double_convert: {
                                    var value = try next_value.toNumber();

                                    if (!std.math.isFinite(value)) {
                                        // for NaN and the string Infinity and -Infinity, parseInt returns NaN
                                        break :double_convert;
                                    }

                                    // simulate parseInt, which converts the argument to a string and
                                    // then back to a number, without converting it to a string
                                    if (value == 0) {
                                        break :brk 0;
                                    }

                                    const sign: i64 = if (value < 0) -1 else 1;
                                    value = @abs(value);
                                    if (value >= max_before_e_notation) {
                                        // toString prints 1.000+e0, which parseInt will stop at
                                        // the '.' or the '+', this gives us a single digit value.
                                        while (value >= 10) value /= 10;
                                        break :brk @as(i64, @intFromFloat(@floor(value))) * sign;
                                    } else if (value < min_before_e_notation) {
                                        // toString prints 1.000-e0, which parseInt will stop at
                                        // the '.' or the '-', this gives us a single digit value.
                                        while (value < 1) value *= 10;
                                        break :brk @as(i64, @intFromFloat(@floor(value))) * sign;
                                    }

                                    // parsing stops at '.', so this is equal to @floor
                                    break :brk @as(i64, @intFromFloat(@floor(value))) * sign;
                                }

                                // for NaN and the string Infinity and -Infinity, parseInt returns NaN
                                this.addForNewLine("NaN".len);
                                writer.print("NaN", .{});
                                continue;
                            };

                            if (int < std.math.maxInt(u32)) {
                                const is_negative = int < 0;
                                const digits = if (i != 0)
                                    bun.fmt.fastDigitCount(@as(u64, @intCast(@abs(int)))) + @as(u64, @intFromBool(is_negative))
                                else
                                    1;
                                this.addForNewLine(digits);
                            } else {
                                this.addForNewLine(std.fmt.count("{d}", .{int}));
                            }
                            writer.print("{d}", .{int});
                        },

                        .f => {
                            // 1. If Type(current) is Symbol, let converted be NaN
                            // 2. Otherwise, let converted be the result of Call(%parseFloat%, undefined, [current]).
                            const converted: f64 = brk: {
                                if (next_value.isInt32()) {
                                    const int = next_value.asInt32();
                                    const is_negative = int < 0;
                                    const digits = if (i != 0)
                                        bun.fmt.fastDigitCount(@as(u64, @intCast(@abs(int)))) + @as(u64, @intFromBool(is_negative))
                                    else
                                        1;
                                    this.addForNewLine(digits);
                                    writer.print("{d}", .{int});
                                    continue;
                                }
                                if (next_value.isNumber()) {
                                    break :brk next_value.asNumber();
                                }
                                if (next_value.isSymbol()) {
                                    break :brk std.math.nan(f64);
                                }
                                // TODO: this is not perfectly emulating parseFloat,
                                // because spec says to convert the value to a string
                                // and then parse as a number, but we are just coercing
                                // a number.
                                break :brk try next_value.toNumber();
                            };

                            const abs = @abs(converted);
                            if (abs < max_before_e_notation and abs >= min_before_e_notation) {
                                this.addForNewLine(std.fmt.count("{d}", .{converted}));
                                writer.print("{d}", .{converted});
                            } else if (std.math.isNan(converted)) {
                                this.addForNewLine("NaN".len);
                                writer.writeAll("NaN");
                            } else if (std.math.isInf(converted)) {
                                this.addForNewLine("Infinity".len + @as(usize, @intFromBool(converted < 0)));
                                if (converted < 0) {
                                    writer.writeAll("-");
                                }
                                writer.writeAll("Infinity");
                            } else {
                                var buf: [124]u8 = undefined;
                                const formatted = bun.fmt.FormatDouble.dtoa(&buf, converted);
                                this.addForNewLine(formatted.len);
                                writer.print("{s}", .{formatted});
                            }
                        },

                        inline .o, .O => |t| {
                            if (t == .o) {
                                // TODO: Node.js applies the following extra formatter options.
                                //
                                // this.max_depth = 4;
                                // this.show_proxy = true;
                                // this.show_hidden = true;
                                //
                                // Spec defines %o as:
                                // > An object with optimally useful formatting is an
                                // > implementation-specific, potentially-interactive representation
                                // > of an object judged to be maximally useful and informative.
                            }
                            try this.format(try Tag.get(next_value, global), Writer, writer_, next_value, global, enable_ansi_colors);
                        },

                        .c => {
                            // TODO: Implement %c
                        },

                        .j => {
                            if (try next_value.jsonStringifyFast()) |result| {
                                var str = result;
                                defer str.deinit();
                                this.addForNewLine(str.length());
                                writer.print("{f}", .{str});
                            } else {
                                this.addForNewLine("undefined".len);
                                writer.writeAll("undefined");
                            }
                        },
                    }
                    if (this.remaining_values.len == 0) break;
                },
                else => {},
            }
        }

        if (slice.len > 0) writer.writeAll(slice);
    }

    pub fn WrappedWriter(comptime Writer: type) type {
        if (Writer != *std.Io.Writer and @hasDecl(Writer, "is_wrapped_writer")) {
            @compileError("Do not nest WrappedWriter");
        }

        return struct {
            ctx: Writer,
            failed: *bool,
            estimated_line_length: *usize,

            pub const is_wrapped_writer = true;

            pub fn print(self: *@This(), comptime fmt: string, args: anytype) void {
                if (self.failed.*) return;
                self.ctx.print(fmt, args) catch {
                    self.failed.* = true;
                };
            }

            pub fn space(self: *@This()) void {
                if (self.failed.*) return;
                self.estimated_line_length.* += 1;
                self.ctx.writeAll(" ") catch {
                    self.failed.* = true;
                };
            }

            pub fn pretty(self: *@This(), comptime fmt: string, comptime enable_ansi_color: bool, args: anytype) void {
                if (self.failed.*) return;
                const length_ignoring_formatted_values = comptime brk: {
                    const fmt_str = Output.prettyFmt(fmt, false);
                    var length: usize = 0;
                    var i: usize = 0;
                    while (i < fmt_str.len) : (i += 1) {
                        switch (fmt_str[i]) {
                            '{' => {
                                i += 1;
                                if (i >= fmt_str.len)
                                    break;
                                if (fmt_str[i] == '{') {
                                    @compileError("Format string too complicated for pretty() right now");
                                }

                                while (i < fmt_str.len) : (i += 1) {
                                    if (fmt_str[i] == '}') {
                                        break;
                                    }
                                }
                                if (i >= fmt_str.len)
                                    break;
                            },
                            128...255 => {
                                @compileError("Format string too complicated for pretty() right now");
                            },
                            else => {},
                        }
                        length += 1;
                    }

                    break :brk length;
                };

                self.estimated_line_length.* += length_ignoring_formatted_values;
                self.ctx.print(comptime Output.prettyFmt(fmt, enable_ansi_color), args) catch {
                    self.failed.* = true;
                };
            }

            pub fn writeLatin1(self: *@This(), buf: []const u8) void {
                if (self.failed.*) return;
                var remain = buf;
                while (remain.len > 0) {
                    if (strings.firstNonASCII(remain)) |i| {
                        if (i > 0) {
                            self.ctx.writeAll(remain[0..i]) catch {
                                self.failed.* = true;
                                return;
                            };
                        }
                        self.ctx.writeAll(&strings.latin1ToCodepointBytesAssumeNotASCII(remain[i])) catch {
                            self.failed.* = true;
                            return;
                        };
                        remain = remain[i + 1 ..];
                    } else {
                        break;
                    }
                }

                self.ctx.writeAll(remain) catch {
                    self.failed.* = true;
                };
            }

            pub inline fn writeAll(self: *@This(), buf: []const u8) void {
                if (self.failed.*) return;
                self.ctx.writeAll(buf) catch {
                    self.failed.* = true;
                };
            }

            pub inline fn writeString(self: *@This(), str: bun.TextView) void {
                self.print("{f}", .{str});
            }

            pub inline fn write16Bit(self: *@This(), input: []const u16) void {
                if (self.failed.*) return;
                bun.fmt.formatUTF16Type(input, self.ctx) catch {
                    self.failed.* = true;
                };
            }
        };
    }

    const indentation_buf: [64]u8 = @splat(' ');
    pub fn writeIndent(
        this: *ConsoleObject.Formatter,
        comptime Writer: type,
        writer: Writer,
    ) !void {
        var total_remain: u32 = this.indent;
        while (total_remain > 0) {
            const written: u8 = @min(32, total_remain);
            try writer.writeAll(indentation_buf[0 .. written * 2]);
            total_remain -|= written;
        }
    }

    pub fn printComma(this: *ConsoleObject.Formatter, comptime _: type, writer: *std.Io.Writer, comptime enable_ansi_colors: bool) !void {
        try writer.writeAll(comptime Output.prettyFmt("<r><d>,<r>", enable_ansi_colors));
        this.estimated_line_length += 1;
    }

    pub fn printNumber(this: anytype, writer: *std.Io.Writer, number: f64, comptime enable_ansi_colors: bool) std.Io.Writer.Error!void {
        if (this.failed) return;
        var buffer: [124]u8 = undefined;
        const formatted = if (std.math.isPositiveInf(number))
            "Infinity"
        else if (std.math.isNegativeInf(number))
            "-Infinity"
        else if (std.math.isNan(number))
            "NaN"
        else
            bun.fmt.FormatDouble.dtoaWithNegativeZero(&buffer, number);
        try printScalar(this, writer, formatted, enable_ansi_colors);
    }

    pub fn printBoolean(this: anytype, writer: *std.Io.Writer, value: bool, comptime enable_ansi_colors: bool) std.Io.Writer.Error!void {
        try printScalar(this, writer, if (value) "true" else "false", enable_ansi_colors);
    }

    pub fn printClassRef(this: anytype, writer: *std.Io.Writer, reference: anytype, comptime enable_ansi_colors: bool) bun.JSError!void {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const value = reference.operand(&scope).asEngine();
        try this.printAs(.Private, @TypeOf(writer), writer, value, value.jsType(), enable_ansi_colors);
    }

    pub fn printOwnedObject(this: anytype, writer: *std.Io.Writer, object: anytype, comptime enable_ansi_colors: bool) bun.JSError!void {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        object.initScope(&scope);
        defer scope.deinit();
        const value = object.operand(&scope).asEngine();
        bun.assert(value.isObject());
        try this.printAs(.Private, @TypeOf(writer), writer, value, .Object, enable_ansi_colors);
    }

    fn printJSONRepresentation(this: *Formatter, comptime Writer: type, writer: *std.Io.Writer, value: JSValue, comptime enable_ansi_colors: bool) bun.JSError!void {
        if (try value.get("toJSON")) |function| {
            const result = try function.call(value.asAny(), &.{});
            const previous = this.quote_keys;
            this.quote_keys = true;
            defer this.quote_keys = previous;
            try this.format(try Tag.get(result, this.globalThis), Writer, writer, result, this.globalThis, enable_ansi_colors);
        } else {
            this.addForNewLine(2);
            writer.writeAll("{}") catch return this.recordWriteFailure();
        }
    }

    fn printScalar(this: anytype, writer: *std.Io.Writer, formatted: []const u8, comptime enable_ansi_colors: bool) std.Io.Writer.Error!void {
        if (this.failed) return;
        this.addForNewLine(formatted.len);
        writer.print(comptime Output.prettyFmt("<r><yellow>{s}<r>", enable_ansi_colors), .{formatted}) catch |err| {
            this.failed = true;
            return err;
        };
    }

    pub fn MapIterator(comptime Writer: type, comptime enable_ansi_colors: bool, comptime is_iterator: bool, comptime single_line: bool) type {
        return struct {
            formatter: *ConsoleObject.Formatter,
            writer: Writer,
            count: usize = 0,
            pub fn forEach(_: *jsc.VM, globalObject: *JSGlobalObject, this: *@This(), nextValue: JSValue) void {
                if (this.formatter.failed) return;
                if (single_line and this.count > 0) {
                    this.formatter.printComma(Writer, this.writer, enable_ansi_colors) catch return this.formatter.recordWriteFailure();
                    this.writer.writeAll(" ") catch return this.formatter.recordWriteFailure();
                }
                if (!is_iterator) {
                    const key = nextValue.getIndex(0) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);
                    const value = nextValue.getIndex(1) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);

                    if (!single_line) {
                        this.formatter.writeIndent(Writer, this.writer) catch return this.formatter.recordWriteFailure();
                    }
                    const key_tag = Tag.getAdvanced(key, globalObject, .{
                        .hide_global = true,
                        .disable_inspect_custom = this.formatter.disable_inspect_custom,
                    }) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);

                    this.formatter.format(
                        key_tag,
                        Writer,
                        this.writer,
                        key,
                        this.formatter.globalThis,
                        enable_ansi_colors,
                    ) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);
                    if (this.formatter.failed) return;
                    this.writer.writeAll(": ") catch return this.formatter.recordWriteFailure();
                    const value_tag = Tag.getAdvanced(value, globalObject, .{
                        .hide_global = true,
                        .disable_inspect_custom = this.formatter.disable_inspect_custom,
                    }) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);
                    this.formatter.format(
                        value_tag,
                        Writer,
                        this.writer,
                        value,
                        this.formatter.globalThis,
                        enable_ansi_colors,
                    ) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);
                } else {
                    if (!single_line) {
                        this.writer.writeAll("\n") catch return this.formatter.recordWriteFailure();
                        this.formatter.writeIndent(Writer, this.writer) catch return this.formatter.recordWriteFailure();
                    }
                    const tag = Tag.getAdvanced(nextValue, globalObject, .{
                        .hide_global = true,
                        .disable_inspect_custom = this.formatter.disable_inspect_custom,
                    }) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);
                    this.formatter.format(
                        tag,
                        Writer,
                        this.writer,
                        nextValue,
                        this.formatter.globalThis,
                        enable_ansi_colors,
                    ) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);
                }
                this.count += 1;
                if (this.formatter.failed) return;
                if (!single_line) {
                    this.formatter.printComma(Writer, this.writer, enable_ansi_colors) catch return this.formatter.recordWriteFailure();
                    if (!is_iterator) {
                        this.writer.writeAll("\n") catch return this.formatter.recordWriteFailure();
                    }
                }
            }
        };
    }

    pub fn SetIterator(comptime Writer: type, comptime enable_ansi_colors: bool, comptime single_line: bool) type {
        return struct {
            formatter: *ConsoleObject.Formatter,
            writer: Writer,
            is_first: bool = true,
            pub fn forEach(_: *jsc.VM, globalObject: *JSGlobalObject, this: *@This(), nextValue: JSValue) void {
                if (this.formatter.failed) return;
                if (single_line) {
                    if (!this.is_first) {
                        this.formatter.printComma(Writer, this.writer, enable_ansi_colors) catch return this.formatter.recordWriteFailure();
                        this.writer.writeAll(" ") catch return this.formatter.recordWriteFailure();
                    }
                    this.is_first = false;
                } else {
                    this.formatter.writeIndent(Writer, this.writer) catch return this.formatter.recordWriteFailure();
                }
                const key_tag = Tag.getAdvanced(nextValue, globalObject, .{
                    .hide_global = true,
                    .disable_inspect_custom = this.formatter.disable_inspect_custom,
                }) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);
                this.formatter.format(
                    key_tag,
                    Writer,
                    this.writer,
                    nextValue,
                    this.formatter.globalThis,
                    enable_ansi_colors,
                ) catch |err| return bun.bindgen.voidFromJSError(err, globalObject);

                if (this.formatter.failed) return;
                if (!single_line) {
                    this.formatter.printComma(Writer, this.writer, enable_ansi_colors) catch return this.formatter.recordWriteFailure();
                    this.writer.writeAll("\n") catch return this.formatter.recordWriteFailure();
                }
            }
        };
    }

    pub fn PropertyIterator(comptime Writer: type, comptime enable_ansi_colors_: bool) type {
        return struct {
            formatter: *ConsoleObject.Formatter,
            writer: Writer,
            i: usize = 0,
            single_line: bool,
            always_newline: bool = false,
            parent: JSValue,
            const enable_ansi_colors = enable_ansi_colors_;
            pub fn handleFirstProperty(this: *@This(), value: JSValue) bun.JSError!void {
                if (value.isCell() and !value.jsType().isFunction()) {
                    var writer = WrappedWriter(Writer){
                        .ctx = this.writer,
                        .failed = &this.formatter.failed,
                        .estimated_line_length = &this.formatter.estimated_line_length,
                    };

                    if (try getObjectName(value)) |name_str| {
                        defer name_str.deref();
                        writer.print("{f} ", .{name_str});
                        if (this.formatter.failed) return;
                    }
                }

                if (!this.single_line) {
                    this.always_newline = true;
                }
                this.formatter.estimated_line_length = this.formatter.indent * 2 + 1;
                this.formatter.indent += 1;
                this.formatter.depth += 1;
                if (this.single_line) {
                    this.writer.writeAll("{ ") catch return this.formatter.recordWriteFailure();
                } else {
                    this.writer.writeAll("{\n") catch return this.formatter.recordWriteFailure();
                    this.formatter.writeIndent(Writer, this.writer) catch return this.formatter.recordWriteFailure();
                }
            }

            pub fn forEach(
                globalThis: *JSGlobalObject,
                ctx: *@This(),
                key: bun.TextView,
                value: JSValue,
                is_symbol: bool,
                is_private_symbol: bool,
            ) void {
                if (key.eqlBytes("constructor")) return;

                var this = ctx.formatter;
                if (this.failed) return;
                const writer_ = ctx.writer;
                var writer = WrappedWriter(Writer){
                    .ctx = writer_,
                    .failed = &this.failed,
                    .estimated_line_length = &this.estimated_line_length,
                };

                const tag = Tag.getAdvanced(value, globalThis, .{
                    .hide_global = true,
                    .disable_inspect_custom = this.disable_inspect_custom,
                }) catch |err| return bun.bindgen.voidFromJSError(err, globalThis);

                if (tag.cell.isHidden()) return;
                if (ctx.i == 0) {
                    handleFirstProperty(ctx, ctx.parent) catch |err| return bun.bindgen.voidFromJSError(err, globalThis);
                    if (this.failed) return;
                } else {
                    this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                }

                defer ctx.i += 1;
                if (ctx.i > 0) {
                    if (!this.single_line and (ctx.always_newline or this.always_newline_scope or this.goodTimeForANewLine())) {
                        writer.writeAll("\n");
                        this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                        this.resetLine();
                    } else {
                        writer.space();
                    }
                }

                if (!is_symbol) {
                    const is_identifier = !this.quote_keys and switch (key) {
                        .utf16 => |slice| JSLexer.isLatin1Identifier(@TypeOf(slice), slice),
                        inline .latin1, .utf8 => |bytes| JSLexer.isLatin1Identifier(@TypeOf(bytes), bytes),
                    };
                    if (is_identifier) {
                        this.addForNewLine(key.len() + 1);

                        writer.print(
                            comptime Output.prettyFmt("<r>{f}<d>:<r> ", enable_ansi_colors),
                            .{key},
                        );
                    } else if (key == .utf16) {
                        var utf16Slice = key.utf16;

                        this.addForNewLine(utf16Slice.len + 2);

                        if (comptime enable_ansi_colors) {
                            writer.writeAll(comptime Output.prettyFmt("<r><green>", true));
                        }

                        writer.writeAll("\"");

                        while (strings.indexOfAny16(utf16Slice, "\"")) |j| {
                            writer.write16Bit(utf16Slice[0..j]);
                            writer.writeAll("\"");
                            utf16Slice = utf16Slice[j + 1 ..];
                        }

                        writer.write16Bit(utf16Slice);

                        writer.print(
                            comptime Output.prettyFmt("\"<r><d>:<r> ", enable_ansi_colors),
                            .{},
                        );
                    } else {
                        this.addForNewLine(key.len() + 2);

                        writer.print(
                            comptime Output.prettyFmt("<r><green>{f}<r><d>:<r> ", enable_ansi_colors),
                            .{bun.fmt.formatJSONStringLatin1(key.byteSlice())},
                        );
                    }
                } else if (Environment.isDebug and is_private_symbol) {
                    const bytes = key.byteSlice();
                    this.addForNewLine(1 + "$:".len + key.len());
                    writer.print(
                        comptime Output.prettyFmt("<r><magenta>{s}{f}<r><d>:<r> ", enable_ansi_colors),
                        .{
                            if (bytes.len > 0 and bytes[0] == '#') "" else "$",
                            key,
                        },
                    );
                } else {
                    this.addForNewLine(1 + "[Symbol()]:".len + key.len());
                    writer.print(
                        comptime Output.prettyFmt("<r><d>[<r><blue>Symbol({f})<r><d>]:<r> ", enable_ansi_colors),
                        .{key},
                    );
                }

                if (this.failed) return;
                if (tag.cell.isStringLike()) {
                    if (comptime enable_ansi_colors) {
                        writer.writeAll(comptime Output.prettyFmt("<r><green>", true));
                    }
                }

                this.format(tag, Writer, ctx.writer, value, globalThis, enable_ansi_colors) catch |err| return bun.bindgen.voidFromJSError(err, globalThis);

                if (tag.cell.isStringLike()) {
                    if (comptime enable_ansi_colors) {
                        writer.writeAll(comptime Output.prettyFmt("<r>", true));
                    }
                }
            }
        };
    }

    fn getObjectName(value: JSValue) bun.JSError!?bun.String {
        const name = try value.className();
        if (!name.eqlComptime("Object"))
            return name;
        name.deref();
        if ((try value.getPrototype()).isNull())
            return bun.String.static("[Object: null prototype]");
        return null;
    }

    pub fn printRetainedArguments(this: *Formatter, comptime Writer: type, writer_: *std.Io.Writer, scope: anytype, values: []const bun.bindgen.Root, comptime enable_ansi_colors: bool) bun.JSError!void {
        if (this.failed) return;
        var writer = WrappedWriter(Writer){ .ctx = writer_, .failed = &this.failed, .estimated_line_length = &this.estimated_line_length };
        if (values.len == 0) {
            writer.writeAll("[]");
            this.addForNewLine(2);
            return;
        }
        var was_good_time = this.always_newline_scope or values.len > 10;
        {
            this.indent += 1;
            this.depth += 1;
            defer this.depth -|= 1;
            defer this.indent -|= 1;
            this.addForNewLine(2);
            const prev_quote_strings = this.quote_strings;
            this.quote_strings = true;
            defer this.quote_strings = prev_quote_strings;

            for (values[0..@min(values.len, 100)], 0..) |*root, index| {
                const element = BindingEscape.borrowEngineValue(scope, BindingEscape.rootValue(scope, root));
                const tag = try Tag.getAdvanced(element, this.globalThis, .{
                    .hide_global = true,
                    .disable_inspect_custom = this.disable_inspect_custom,
                });
                if (index == 0) {
                    was_good_time = was_good_time or !tag.tag.isPrimitive() or this.goodTimeForANewLine();
                    if (!this.single_line and (this.ordered_properties or was_good_time)) {
                        this.resetLine();
                        writer.writeAll("[\n");
                        this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                        this.addForNewLine(1);
                    } else {
                        writer.writeAll("[ ");
                        this.addForNewLine(2);
                    }
                } else {
                    this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                    if (!this.single_line and (this.ordered_properties or this.goodTimeForANewLine())) {
                        writer.writeAll("\n");
                        was_good_time = true;
                        this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                    } else {
                        writer.space();
                    }
                }
                try this.format(tag, Writer, writer_, element, this.globalThis, enable_ansi_colors);
                if (enable_ansi_colors and tag.cell.isStringLike()) {
                    writer.writeAll(comptime Output.prettyFmt("<r>", true));
                }
            }
            if (values.len > 100) {
                this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                writer.writeAll("\n");
                this.estimated_line_length = 0;
                this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                writer.pretty("<r><d>... {d} more items<r>", enable_ansi_colors, .{values.len - 100});
            }
        }
        if (!this.single_line and (this.ordered_properties or was_good_time or this.goodTimeForANewLine())) {
            this.resetLine();
            writer.writeAll("\n");
            this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
            writer.writeAll("]");
            this.resetLine();
            this.addForNewLine(1);
        } else {
            writer.writeAll(" ]");
            this.addForNewLine(2);
        }
    }

    pub fn printAs(
        this: *ConsoleObject.Formatter,
        comptime Format: ConsoleObject.Formatter.Tag,
        comptime Writer: type,
        writer_: *std.Io.Writer,
        value: JSValue,
        jsType: JSValue.JSType,
        comptime enable_ansi_colors: bool,
    ) bun.JSError!void {
        if (this.failed)
            return;
        if (this.globalThis.hasException()) {
            return error.JSError;
        }

        // If we call
        //   `return try this.printAs`
        //
        // Then we can get a spurious `[Circular]` due to the value already being present in the map.
        var remove_before_recurse = false;

        var writer = WrappedWriter(Writer){ .ctx = writer_, .failed = &this.failed, .estimated_line_length = &this.estimated_line_length };
        if (comptime Format.canHaveCircularReferences()) {
            if (this.stack_check == null) this.stack_check = bun.StackCheck.init();
            if (!this.stack_check.?.isSafeToRecurse()) {
                this.failed = true;
                if (this.can_throw_stack_overflow) {
                    return this.globalThis.throwStackOverflow();
                }
                return;
            }

            if (this.map_node == null) {
                this.map_node = try Visited.Pool.tryGet(default_allocator);
                this.map_node.?.data.clearRetainingCapacity();
                this.map = this.map_node.?.data;
            }

            const entry = try this.map.getOrPut(rawValue(value));
            if (entry.found_existing) {
                writer.writeAll(comptime Output.prettyFmt("<r><cyan>[Circular]<r>", enable_ansi_colors));
                return;
            } else {
                remove_before_recurse = true;
            }
        }

        defer {
            if (comptime Format.canHaveCircularReferences()) {
                if (remove_before_recurse) {
                    _ = this.map.remove(rawValue(value));
                }
            }
        }

        switch (comptime Format) {
            .StringPossiblyFormatted => {
                var str = try value.toSlice(bun.default_allocator);
                defer str.deinit();
                this.addForNewLine(str.length());
                const slice = str.slice();
                try this.writeWithFormatting(Writer, writer_, @TypeOf(slice), slice, this.globalThis, enable_ansi_colors);
            },
            .String => {
                // This is called from the '%s' formatter, so it can actually be any value
                const str = try value.toBunString();
                defer str.deref();
                this.addForNewLine(str.length());

                if (this.quote_strings and jsType != .RegExpObject) {
                    if (str.isEmpty()) {
                        writer.writeAll("\"\"");
                        return;
                    }

                    if (comptime enable_ansi_colors) {
                        writer.writeAll(Output.prettyFmt("<r><green>", true));
                    }

                    defer if (comptime enable_ansi_colors)
                        writer.writeAll(Output.prettyFmt("<r>", true));

                    if (str.isUTF16()) {
                        try this.printAs(.JSON, Writer, writer_, value, .StringObject, enable_ansi_colors);
                        return;
                    }

                    JSPrinter.writeJSONString(str.latin1(), Writer, writer_, .latin1) catch return this.recordWriteFailure();

                    return;
                }

                if (jsType == .StringObject) {
                    if (enable_ansi_colors) {
                        writer.print(comptime Output.prettyFmt("<r><green>", enable_ansi_colors), .{});
                    }
                    defer if (comptime enable_ansi_colors)
                        writer.writeAll(Output.prettyFmt("<r>", true));

                    writer.print("[String: ", .{});

                    if (str.isUTF16()) {
                        try this.printAs(.JSON, Writer, writer_, value, .StringObject, enable_ansi_colors);
                    } else {
                        JSPrinter.writeJSONString(str.latin1(), Writer, writer_, .latin1) catch return this.recordWriteFailure();
                    }

                    writer.print("]", .{});
                    return;
                }

                if (jsType == .RegExpObject and enable_ansi_colors) {
                    writer.print(comptime Output.prettyFmt("<r><red>", enable_ansi_colors), .{});
                }

                if (str.isUTF16()) {
                    // streaming print
                    writer.print("{f}", .{str});
                } else if (str.asUTF8()) |slice| {
                    // fast path
                    writer.writeAll(slice);
                } else if (!str.isEmpty()) {
                    // slow path
                    const buf = strings.allocateLatin1IntoUTF8(bun.default_allocator, str.latin1()) catch &[_]u8{};
                    if (buf.len > 0) {
                        defer bun.default_allocator.free(buf);
                        writer.writeAll(buf);
                    }
                }

                if (jsType == .RegExpObject and enable_ansi_colors) {
                    writer.print(comptime Output.prettyFmt("<r>", enable_ansi_colors), .{});
                }
            },
            .Integer => {
                const int = try value.coerce(i64);
                if (int < std.math.maxInt(u32)) {
                    var i = int;
                    const is_negative = i < 0;
                    if (is_negative) {
                        i = -i;
                    }
                    const digits = if (i != 0)
                        bun.fmt.fastDigitCount(@as(usize, @intCast(i))) + @as(usize, @intFromBool(is_negative))
                    else
                        1;
                    this.addForNewLine(digits);
                } else {
                    this.addForNewLine(std.fmt.count("{d}", .{int}));
                }
                writer.print(comptime Output.prettyFmt("<r><yellow>{d}<r>", enable_ansi_colors), .{int});
            },
            .BigInt => {
                var out_string = try value.toBunString();
                defer out_string.deref();
                const out_str = out_string.byteSlice();
                this.addForNewLine(out_str.len);

                writer.print(comptime Output.prettyFmt("<r><yellow>{s}n<r>", enable_ansi_colors), .{out_str});
            },
            .Double => {
                if (value.isCell()) {
                    const number_name = try value.className();
                    defer number_name.deref();

                    var number_string = try value.toBunString();
                    defer number_string.deref();
                    const number_value = number_string.textView();

                    if (!number_name.eqlComptime("Number")) {
                        this.addForNewLine(number_name.length() + number_value.len() + "[Number ():]".len);
                        writer.print(comptime Output.prettyFmt("<r><yellow>[Number ({f}): {f}]<r>", enable_ansi_colors), .{
                            number_name,
                            number_value,
                        });
                        return;
                    }

                    this.addForNewLine(number_name.length() + number_value.len() + 4);
                    writer.print(comptime Output.prettyFmt("<r><yellow>[{f}: {f}]<r>", enable_ansi_colors), .{
                        number_name,
                        number_value,
                    });
                    return;
                }

                this.printNumber(writer_, value.asNumber(), enable_ansi_colors) catch return this.recordWriteFailure();
            },
            .Undefined => {
                this.addForNewLine(9);
                writer.print(comptime Output.prettyFmt("<r><d>undefined<r>", enable_ansi_colors), .{});
            },
            .Null => {
                this.addForNewLine(4);
                writer.print(comptime Output.prettyFmt("<r><yellow>null<r>", enable_ansi_colors), .{});
            },
            .CustomFormattedObject => {
                // Call custom inspect function. Will return the error if there is one
                // we'll need to pass the callback through to the "this" value in here
                const custom_formatted_object = this.custom_formatted_object.?;
                const scope = value;
                const returned = try scope.engine(CallCustomInspectFunctionSchema).call(.{
                    .function = custom_formatted_object.function,
                    .thisValue = custom_formatted_object.this,
                    .depth = @as(i32, this.max_depth) - @as(i32, this.depth),
                    .maxDepth = this.max_depth,
                    .colors = enable_ansi_colors,
                    .sorted = this.ordered_properties,
                    .compact = this.single_line,
                });
                const result = returned.operand(&scope).asEngine();
                // Strings are printed directly, otherwise we recurse. It is possible to end up in an infinite loop.
                if (result.isString()) {
                    const result_string = try result.toBunString();
                    defer result_string.deref();
                    const text = try result_string.toUTF8(bun.default_allocator);
                    defer text.deinit();
                    var lines = std.mem.splitScalar(u8, text.slice(), '\n');
                    writer.writeAll(lines.next().?);
                    while (lines.next()) |line| {
                        writer.writeAll("\n");
                        this.resetLine();
                        this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                        writer.writeAll(line);
                    }
                } else if (result.eqlValue(custom_formatted_object.this)) {
                    remove_before_recurse = false;
                    _ = this.map.remove(rawValue(value));
                    const tag = try Tag.getAdvanced(result, this.globalThis, .{ .disable_inspect_custom = true });
                    try this.format(tag, Writer, writer_, result, this.globalThis, enable_ansi_colors);
                } else {
                    try this.format(try ConsoleObject.Formatter.Tag.get(result, this.globalThis), Writer, writer_, result, this.globalThis, enable_ansi_colors);
                }
            },
            .Symbol => {
                const description = try value.getDescription();
                defer description.deref();
                const description_length = description.length();
                this.addForNewLine("Symbol".len);

                if (description_length > 0) {
                    this.addForNewLine(description_length + "()".len);
                    writer.print(comptime Output.prettyFmt("<r><blue>Symbol({f})<r>", enable_ansi_colors), .{description});
                } else {
                    writer.print(comptime Output.prettyFmt("<r><blue>Symbol()<r>", enable_ansi_colors), .{});
                }
            },
            .Error => {
                // Temporarily remove from the visited map to allow printErrorlikeObject to process it
                // The circular reference check is already done in printAs, so we know it's safe
                const was_in_map = if (this.map_node != null) this.map.remove(rawValue(value)) else false;
                defer if (was_in_map) {
                    this.map.putAssumeCapacity(rawValue(value), {});
                };

                try VirtualMachine.get().printErrorlikeObject(
                    value,
                    null,
                    this,
                    Writer,
                    writer_,
                    enable_ansi_colors,
                    false,
                );
            },
            .Class => {
                // Prefer the constructor's own `.name` property over
                // `getClassName` / `calculatedClassName`. For DOM / WebCore
                // InternalFunction constructors like `ReadableStreamBYOBReader`,
                // `calculatedClassName` walks the prototype chain and hits
                // `Function.prototype.constructor === Function`, returning
                // "Function". The `.name` property is set to the real class
                // name on the constructor itself. See #29225.
                var printable = try value.getName();
                defer printable.deref();
                this.addForNewLine(printable.length());

                // Only report `extends` when the parent is itself a class
                // (i.e. `class Foo extends Bar`). Built-in and DOM constructors
                // have `Function.prototype` as their prototype, which would
                // render as `[class X extends Function]` and is noise.
                const proto = try value.getPrototype();
                const proto_is_class = !proto.isEmptyOrUndefinedOrNull() and proto.isCell() and proto.isClass();
                var printable_proto: bun.String = if (proto_is_class) try proto.getName() else bun.String.empty;
                defer printable_proto.deref();
                this.addForNewLine(printable_proto.length());

                if (printable.isEmpty()) {
                    if (printable_proto.isEmpty()) {
                        writer.print(comptime Output.prettyFmt("<cyan>[class (anonymous)]<r>", enable_ansi_colors), .{});
                    } else {
                        writer.print(comptime Output.prettyFmt("<cyan>[class (anonymous) extends {f}]<r>", enable_ansi_colors), .{printable_proto});
                    }
                } else {
                    if (printable_proto.isEmpty()) {
                        writer.print(comptime Output.prettyFmt("<cyan>[class {f}]<r>", enable_ansi_colors), .{printable});
                    } else {
                        writer.print(comptime Output.prettyFmt("<cyan>[class {f} extends {f}]<r>", enable_ansi_colors), .{ printable, printable_proto });
                    }
                }
            },
            .Function => {
                var printable = try value.getName();
                defer printable.deref();

                const proto = try value.getPrototype();
                const func_name = try proto.getName(); // "Function" | "AsyncFunction" | "GeneratorFunction" | "AsyncGeneratorFunction"
                defer func_name.deref();

                if (printable.isEmpty() or func_name.eql(printable)) {
                    if (func_name.isEmpty()) {
                        writer.print(comptime Output.prettyFmt("<cyan>[Function]<r>", enable_ansi_colors), .{});
                    } else {
                        writer.print(comptime Output.prettyFmt("<cyan>[{f}]<r>", enable_ansi_colors), .{func_name});
                    }
                } else {
                    if (func_name.isEmpty()) {
                        writer.print(comptime Output.prettyFmt("<cyan>[Function: {f}]<r>", enable_ansi_colors), .{printable});
                    } else {
                        writer.print(comptime Output.prettyFmt("<cyan>[{f}: {f}]<r>", enable_ansi_colors), .{ func_name, printable });
                    }
                }
            },
            .GetterSetter, .CustomGetterSetter => {
                const Schema = if (comptime Format == .GetterSetter) InspectGetterSetterSchema else InspectCustomGetterSetterSchema;
                const scope = value;
                const presence = scope.engine(Schema).call(.{ .value = value });
                if (presence.getter and presence.setter) {
                    writer.print(comptime Output.prettyFmt("<cyan>[Getter/Setter]<r>", enable_ansi_colors), .{});
                } else if (presence.getter) {
                    writer.print(comptime Output.prettyFmt("<cyan>[Getter]<r>", enable_ansi_colors), .{});
                } else if (presence.setter) {
                    writer.print(comptime Output.prettyFmt("<cyan>[Setter]<r>", enable_ansi_colors), .{});
                }
            },
            .Array => {
                const scope = value;
                const Properties = bun.bindgen.Module("property_accessors");
                const OwnIndex = Properties.engineShim("jsObjectGetOwnIndex");
                const array = value;
                const len = try scope.engine(Properties.engineShim("jsValueGetIndexedLength")).call(.{ .value = array });

                if (len == 0) {
                    writer.writeAll("[]");
                    this.addForNewLine(2);
                    return;
                }

                var was_good_time = this.always_newline_scope or
                    // heuristic: more than 10, probably should have a newline before it
                    len > 10;
                {
                    this.indent += 1;
                    this.depth += 1;
                    defer this.depth -|= 1;
                    defer this.indent -|= 1;

                    this.addForNewLine(2);

                    const prev_quote_strings = this.quote_strings;
                    this.quote_strings = true;
                    defer this.quote_strings = prev_quote_strings;
                    var empty_start: ?u64 = null;
                    first: {
                        const first_result = try scope.engine(OwnIndex).call(.{ .object = array, .index = 0 });
                        const first_element = if (first_result) |element| element.operand(&scope).asEngine() else null;

                        const tag: Tag.Result = if (first_element) |el| try Tag.getAdvanced(el, this.globalThis, .{
                            .hide_global = true,
                            .disable_inspect_custom = this.disable_inspect_custom,
                        }) else .{ .tag = .Undefined };

                        was_good_time = was_good_time or !tag.tag.isPrimitive() or this.goodTimeForANewLine();

                        if (!this.single_line and (this.ordered_properties or was_good_time)) {
                            this.resetLine();
                            writer.writeAll("[");
                            writer.writeAll("\n");
                            this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                            this.addForNewLine(1);
                        } else {
                            writer.writeAll("[ ");
                            this.addForNewLine(2);
                        }

                        const element = first_element orelse {
                            empty_start = 0;
                            break :first;
                        };

                        try this.format(tag, Writer, writer_, element, this.globalThis, enable_ansi_colors);

                        if (tag.cell.isStringLike()) {
                            if (comptime enable_ansi_colors) {
                                writer.writeAll(comptime Output.prettyFmt("<r>", true));
                            }
                        }
                    }

                    var i: u64 = 1;
                    var nonempty_count: u32 = if (empty_start == null) 1 else 0;

                    while (i < len) : (i += 1) {
                        const element_result = (try scope.engine(OwnIndex).call(.{ .object = array, .index = i })) orelse {
                            if (empty_start == null) {
                                empty_start = i;
                            }
                            continue;
                        };
                        const element = element_result.operand(&scope).asEngine();
                        if (nonempty_count >= 100) {
                            this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                            writer.writeAll("\n"); // we want the line break to be unconditional here
                            this.estimated_line_length = 0;
                            this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                            writer.pretty("<r><d>... {d} more items<r>", enable_ansi_colors, .{len - i});
                            break;
                        }
                        nonempty_count += 1;

                        if (empty_start) |empty| {
                            if (empty > 0) {
                                this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                                if (!this.single_line and (this.ordered_properties or this.goodTimeForANewLine())) {
                                    was_good_time = true;
                                    writer.writeAll("\n");
                                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                } else {
                                    writer.space();
                                }
                            }
                            const empty_count = i - empty;
                            if (empty_count == 1) {
                                writer.pretty("<r><d>empty item<r>", enable_ansi_colors, .{});
                            } else {
                                this.estimated_line_length += bun.fmt.fastDigitCount(empty_count);
                                writer.pretty("<r><d>{d} x empty items<r>", enable_ansi_colors, .{empty_count});
                            }
                            empty_start = null;
                        }

                        this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                        if (!this.single_line and (this.ordered_properties or this.goodTimeForANewLine())) {
                            writer.writeAll("\n");
                            was_good_time = true;
                            this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                        } else {
                            writer.space();
                        }

                        const tag = try Tag.getAdvanced(element, this.globalThis, .{
                            .hide_global = true,
                            .disable_inspect_custom = this.disable_inspect_custom,
                        });

                        try this.format(tag, Writer, writer_, element, this.globalThis, enable_ansi_colors);

                        if (tag.cell.isStringLike()) {
                            if (comptime enable_ansi_colors) {
                                writer.writeAll(comptime Output.prettyFmt("<r>", true));
                            }
                        }
                    }

                    if (empty_start) |empty| {
                        if (empty > 0) {
                            this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                            if (!this.single_line and (this.ordered_properties or this.goodTimeForANewLine())) {
                                writer.writeAll("\n");
                                was_good_time = true;
                                this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                            } else {
                                writer.space();
                            }
                        }

                        empty_start = null;

                        const empty_count = len - empty;
                        if (empty_count == 1) {
                            writer.pretty("<r><d>empty item<r>", enable_ansi_colors, .{});
                        } else {
                            this.estimated_line_length += bun.fmt.fastDigitCount(empty_count);
                            writer.pretty("<r><d>{d} x empty items<r>", enable_ansi_colors, .{empty_count});
                        }
                    }

                    if (!jsType.isArguments()) {
                        const Iterator = PropertyIterator(Writer, enable_ansi_colors);
                        var iter = Iterator{
                            .formatter = this,
                            .writer = writer_,
                            .always_newline = !this.single_line and (this.always_newline_scope or this.goodTimeForANewLine()),
                            .single_line = this.single_line,
                            .parent = value,
                            .i = i,
                        };
                        try value.forEachPropertyNonIndexed(&iter, Iterator.forEach);
                        if (this.failed) return;
                    }
                }

                if (!this.single_line and (this.ordered_properties or was_good_time or this.goodTimeForANewLine())) {
                    this.resetLine();
                    writer.writeAll("\n");
                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                    writer.writeAll("]");
                    this.resetLine();
                    this.addForNewLine(1);
                } else {
                    writer.writeAll(" ]");
                    this.addForNewLine(2);
                }
            },
            .Private => {
                if (try jsc.WebCore.Response.Binding.tryCastRef(rawValue(value), this.globalThis)) |response_ref| {
                    var reference = response_ref;
                    defer reference.deinit();
                    jsc.WebCore.ResponseEngine.writeFormat(&reference, ConsoleObject.Formatter, this, writer_, enable_ansi_colors) catch |err| switch (err) {
                        error.WriteFailed => this.failed = true,
                        else => |js_error| return js_error,
                    };
                    return;
                } else if (try jsc.WebCore.Request.Binding.tryCastRef(rawValue(value), this.globalThis)) |request_ref| {
                    var reference = request_ref;
                    defer reference.deinit();
                    jsc.WebCore.RequestEngine.writeFormat(&reference, ConsoleObject.Formatter, this, writer_, enable_ansi_colors) catch |err| switch (err) {
                        error.WriteFailed => this.failed = true,
                        else => |failure| return failure,
                    };
                    return;
                } else if (try jsc.API.BuildArtifact.Binding.tryCastRef(rawValue(value), this.globalThis)) |build_ref| {
                    var build = build_ref;
                    defer build.deinit();
                    build.get(jsc.API.BuildArtifact).writeFormat(&build, this.globalThis, ConsoleObject.Formatter, this, writer_, enable_ansi_colors) catch |err| switch (err) {
                        error.WriteFailed => this.failed = true,
                        else => |failure| return failure,
                    };
                    return;
                } else if (try jsc.WebCore.Blob.BlobClass.tryCast(rawValue(value), this.globalThis)) |blob_handle| {
                    var blob = blob_handle;
                    defer blob.deinit();
                    blob.get().native().writeFormat(ConsoleObject.Formatter, this, writer_, enable_ansi_colors) catch |err| switch (err) {
                        error.WriteFailed => this.failed = true,
                        else => |failure| return failure,
                    };
                    return;
                } else if (try jsc.WebCore.S3ClientModule.S3ClientClass.tryCast(rawValue(value), this.globalThis)) |s3client_handle| {
                    var s3client = s3client_handle;
                    defer s3client.deinit();
                    jsc.WebCore.S3ClientEngine.writeFormat(s3client.get(), ConsoleObject.Formatter, this, writer_, enable_ansi_colors) catch |err| switch (err) {
                        error.WriteFailed => this.failed = true,
                        else => |failure| return failure,
                    };
                    return;
                } else if (try jsc.API.Archive.Binding.tryCast(rawValue(value), this.globalThis)) |archive_handle| {
                    var archive = archive_handle;
                    defer archive.deinit();
                    jsc.API.ArchiveEngine.writeFormat(archive.get(), ConsoleObject.Formatter, this, writer_, enable_ansi_colors) catch |err| switch (err) {
                        error.WriteFailed => this.failed = true,
                        else => |failure| return failure,
                    };
                    return;
                } else if (@import("./URLSearchParams.zig").URLSearchParamsObject.Binding.isInstance(rawValue(value))) {
                    return this.printJSONRepresentation(Writer, writer_, value, enable_ansi_colors);
                } else if (Headers.Binding.isInstance(rawValue(value))) {
                    const toJSONFunction = BindingEscape.borrowEngineValue(value, try Headers.Binding.methodFunction("toJSON", this.globalThis));
                    this.addForNewLine("Headers ".len);
                    writer.writeAll(comptime Output.prettyFmt("<r>Headers ", enable_ansi_colors));
                    const prev_quote_keys = this.quote_keys;
                    this.quote_keys = true;
                    defer this.quote_keys = prev_quote_keys;

                    const json = try toJSONFunction.call(value.asAny(), &.{});
                    return try this.printAs(
                        .Object,
                        Writer,
                        writer_,
                        json,
                        .Object,
                        enable_ansi_colors,
                    );
                } else if (try bun.api.Timer.TimeoutObject.Binding.tryCast(rawValue(value), this.globalThis)) |timeout_handle| {
                    var handle = timeout_handle;
                    defer handle.deinit();
                    const timer = handle.get().timeout.get();
                    this.addForNewLine("Timeout(# ) ".len + bun.fmt.fastDigitCount(@as(u64, @intCast(@max(timer.internals.id, 0)))));
                    if (timer.internals.flags.kind == .setInterval) {
                        this.addForNewLine("repeats ".len + bun.fmt.fastDigitCount(@as(u64, @intCast(@max(timer.internals.id, 0)))));
                        writer.print(comptime Output.prettyFmt("<r><blue>Timeout<r> <d>(#<yellow>{d}<r><d>, repeats)<r>", enable_ansi_colors), .{
                            timer.internals.id,
                        });
                    } else {
                        writer.print(comptime Output.prettyFmt("<r><blue>Timeout<r> <d>(#<yellow>{d}<r><d>)<r>", enable_ansi_colors), .{
                            timer.internals.id,
                        });
                    }

                    return;
                } else if (try bun.api.Timer.ImmediateObject.Binding.tryCast(rawValue(value), this.globalThis)) |immediate_handle| {
                    var handle = immediate_handle;
                    defer handle.deinit();
                    const immediate = handle.get().immediate.get();
                    this.addForNewLine("Immediate(# ) ".len + bun.fmt.fastDigitCount(@as(u64, @intCast(@max(immediate.internals.id, 0)))));
                    writer.print(comptime Output.prettyFmt("<r><blue>Immediate<r> <d>(#<yellow>{d}<r><d>)<r>", enable_ansi_colors), .{
                        immediate.internals.id,
                    });

                    return;
                } else if (try JestPrettyFormat.printAsymmetricMatcher(this, Format, &writer, writer_, value, enable_ansi_colors)) {
                    return;
                } else if (jsType != .DOMWrapper) {
                    if (remove_before_recurse) {
                        remove_before_recurse = false;
                        _ = this.map.remove(rawValue(value));
                    }

                    if (value.isCallable()) {
                        remove_before_recurse = true;
                        return try this.printAs(.Function, Writer, writer_, value, jsType, enable_ansi_colors);
                    }

                    remove_before_recurse = true;
                    return try this.printAs(.Object, Writer, writer_, value, jsType, enable_ansi_colors);
                }
                if (remove_before_recurse) {
                    remove_before_recurse = false;
                    _ = this.map.remove(rawValue(value));
                }

                remove_before_recurse = true;
                return try this.printAs(.Object, Writer, writer_, value, .Event, enable_ansi_colors);
            },
            .NativeCode => {
                if (try value.getClassInfoName()) |class_name| {
                    defer class_name.deref();
                    const class_name_bytes = class_name.byteSlice();
                    this.addForNewLine("[native code: ]".len + class_name_bytes.len);
                    writer.writeAll("[native code: ");
                    writer.writeAll(class_name_bytes);
                    writer.writeAll("]");
                } else {
                    this.addForNewLine("[native code]".len);
                    writer.writeAll("[native code]");
                }
            },
            .Promise => {
                if (!this.single_line and this.goodTimeForANewLine()) {
                    writer.writeAll("\n");
                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                }

                writer.writeAll("Promise { " ++ comptime Output.prettyFmt("<r><cyan>", enable_ansi_colors));

                const scope = value;
                const promise = (try scope.engineIn("promises", "jsValueAsPromise").call(.{
                    .value = value,
                })) orelse @panic("Promise formatter received a non-promise");
                switch (scope.engineIn("promises", "promiseStatus").call(.{ .promise = promise.operand(&scope) })) {
                    .pending => writer.writeAll("<pending>"),
                    .fulfilled => writer.writeAll("<resolved>"),
                    .rejected => writer.writeAll("<rejected>"),
                }

                writer.writeAll(comptime Output.prettyFmt("<r>", enable_ansi_colors) ++ " }");
            },
            .Boolean => {
                if (value.isCell()) {
                    const bool_name = try value.className();
                    defer bool_name.deref();
                    var bool_string = try value.toBunString();
                    defer bool_string.deref();
                    const bool_value = bool_string.textView();

                    if (!bool_name.eqlComptime("Boolean")) {
                        this.addForNewLine(bool_value.len() + bool_name.length() + "[Boolean (): ]".len);
                        writer.print(comptime Output.prettyFmt("<r><yellow>[Boolean ({f}): {f}]<r>", enable_ansi_colors), .{
                            bool_name,
                            bool_value,
                        });
                        return;
                    }
                    this.addForNewLine(bool_value.len() + "[Boolean: ]".len);
                    writer.print(comptime Output.prettyFmt("<r><yellow>[Boolean: {f}]<r>", enable_ansi_colors), .{bool_value});
                    return;
                }
                this.printBoolean(writer_, value.toBoolean(), enable_ansi_colors) catch return this.recordWriteFailure();
            },
            .GlobalObject => {
                const fmt = "[Global Object]";
                this.addForNewLine(fmt.len);
                writer.writeAll(comptime Output.prettyFmt("<cyan>" ++ fmt ++ "<r>", enable_ansi_colors));
            },
            .Map => {
                const length_value = try value.get("size") orelse BindingEscape.borrowEngineValue(value, jsc.JSValue.jsNumberFromInt32(0));
                const length = try length_value.coerce(i32);

                const prev_quote_strings = this.quote_strings;
                this.quote_strings = true;
                defer this.quote_strings = prev_quote_strings;

                const map_name = if (value.jsType() == .WeakMap) "WeakMap" else "Map";

                if (length == 0) {
                    return writer.print("{s} {{}}", .{map_name});
                }

                switch (this.single_line) {
                    inline else => |single_line| {
                        writer.print("{s}({d}) {{" ++ (if (single_line) " " else "\n"), .{ map_name, length });
                    },
                }
                {
                    this.indent += 1;
                    this.depth +|= 1;
                    defer this.indent -|= 1;
                    defer this.depth -|= 1;
                    switch (this.single_line) {
                        inline else => |single_line| {
                            var iter = MapIterator(Writer, enable_ansi_colors, false, single_line){
                                .formatter = this,
                                .writer = writer_,
                            };
                            try value.forEach(&iter, @TypeOf(iter).forEach);
                            if (this.failed) return;
                            if (single_line and iter.count > 0) {
                                writer.writeAll(" ");
                            }
                        },
                    }
                }
                if (!this.single_line) {
                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                }
                writer.writeAll("}");
            },
            .MapIterator => {
                const prev_quote_strings = this.quote_strings;
                this.quote_strings = true;
                defer this.quote_strings = prev_quote_strings;

                writer.print("MapIterator {{ ", .{});
                {
                    this.indent += 1;
                    this.depth +|= 1;
                    defer this.indent -|= 1;
                    defer this.depth -|= 1;
                    switch (this.single_line) {
                        inline else => |single_line| {
                            var iter = MapIterator(Writer, enable_ansi_colors, true, single_line){
                                .formatter = this,
                                .writer = writer_,
                            };
                            try value.forEach(&iter, @TypeOf(iter).forEach);
                            if (this.failed) return;
                            if (iter.count > 0) {
                                if (single_line) {
                                    writer.writeAll(" ");
                                } else {
                                    writer.writeAll("\n");
                                }
                            }
                        },
                    }
                }
                if (!this.single_line) {
                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                }
                writer.writeAll("}");
            },
            .SetIterator => {
                const prev_quote_strings = this.quote_strings;
                this.quote_strings = true;
                defer this.quote_strings = prev_quote_strings;

                writer.print("SetIterator {{ ", .{});
                {
                    this.indent += 1;
                    this.depth +|= 1;
                    defer this.indent -|= 1;
                    defer this.depth -|= 1;
                    switch (this.single_line) {
                        inline else => |single_line| {
                            var iter = MapIterator(Writer, enable_ansi_colors, true, single_line){
                                .formatter = this,
                                .writer = writer_,
                            };
                            try value.forEach(&iter, @TypeOf(iter).forEach);
                            if (this.failed) return;
                            if (iter.count > 0 and !single_line) {
                                writer.writeAll("\n");
                            }
                        },
                    }
                }
                if (!this.single_line) {
                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                }
                writer.writeAll("}");
            },
            .Set => {
                const length_value = try value.get("size") orelse BindingEscape.borrowEngineValue(value, jsc.JSValue.jsNumberFromInt32(0));
                const length = try length_value.coerce(i32);

                const prev_quote_strings = this.quote_strings;
                this.quote_strings = true;
                defer this.quote_strings = prev_quote_strings;

                const set_name = if (value.jsType() == .WeakSet) "WeakSet" else "Set";

                if (length == 0) {
                    return writer.print("{s} {{}}", .{set_name});
                }

                switch (this.single_line) {
                    inline else => |single_line| {
                        writer.print("{s}({d}) {{" ++ (if (single_line) " " else "\n"), .{ set_name, length });
                    },
                }
                {
                    this.indent += 1;
                    this.depth +|= 1;
                    defer this.indent -|= 1;
                    defer this.depth -|= 1;
                    switch (this.single_line) {
                        inline else => |single_line| {
                            var iter = SetIterator(Writer, enable_ansi_colors, single_line){
                                .formatter = this,
                                .writer = writer_,
                            };
                            try value.forEach(&iter, @TypeOf(iter).forEach);
                            if (this.failed) return;
                            if (single_line and !iter.is_first) {
                                writer.writeAll(" ");
                            }
                        },
                    }
                }
                if (!this.single_line) {
                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                }
                writer.writeAll("}");
            },
            .toJSON => {
                return this.printJSONRepresentation(Writer, writer_, value, enable_ansi_colors);
            },
            .JSON => {
                var str = (try value.jsonStringify(this.indent)) orelse {
                    this.addForNewLine("undefined".len);
                    writer.writeAll("undefined");
                    return;
                };
                defer str.deinit();
                this.addForNewLine(str.length());
                if (jsType == JSValue.JSType.JSDate) {
                    // in the code for printing dates, it never exceeds this amount
                    var iso_string_buf: [36]u8 = undefined;
                    var out_buf: []const u8 = std.fmt.bufPrint(&iso_string_buf, "{f}", .{str}) catch "";

                    if (strings.eql(out_buf, "null")) {
                        out_buf = "Invalid Date";
                    } else if (out_buf.len > 2) {
                        // trim the quotes
                        out_buf = out_buf[1 .. out_buf.len - 1];
                    }

                    writer.print(comptime Output.prettyFmt("<r><magenta>{s}<r>", enable_ansi_colors), .{out_buf});
                    return;
                }

                writer.print("{f}", .{str});
            },
            .Event => {
                const event_type_value: JSValue = brk: {
                    const value_ = try value.get("type") orelse break :brk BindingEscape.borrowEngineValue(value, .js_undefined);
                    if (value_.isString()) {
                        break :brk value_;
                    }

                    break :brk BindingEscape.borrowEngineValue(value, .js_undefined);
                };

                const event_type_string = try event_type_value.toBunString();
                defer event_type_string.deref();
                const event_type = switch (EventType.map.fromString(event_type_string) orelse .unknown) {
                    .MessageEvent, .ErrorEvent => |evt| evt,
                    else => {
                        if (remove_before_recurse) {
                            _ = this.map.remove(rawValue(value));
                        }

                        // We must potentially remove it again.
                        remove_before_recurse = true;
                        return try this.printAs(.Object, Writer, writer_, value, .Event, enable_ansi_colors);
                    },
                };

                writer.print(
                    comptime Output.prettyFmt("<r><cyan>{s}<r> {{\n", enable_ansi_colors),
                    .{
                        @tagName(event_type),
                    },
                );
                {
                    this.indent += 1;
                    this.depth +|= 1;
                    defer this.indent -|= 1;
                    defer this.depth -|= 1;
                    const old_quote_strings = this.quote_strings;
                    this.quote_strings = true;
                    defer this.quote_strings = old_quote_strings;
                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();

                    switch (this.single_line) {
                        inline else => |single_line| {
                            writer.print(
                                comptime Output.prettyFmt("<r>type: <green>\"{s}\"<r><d>,<r>" ++ (if (single_line) " " else "\n"), enable_ansi_colors),
                                .{
                                    event_type.label(),
                                },
                            );
                        },
                    }

                    if (try value.fastGet(.message)) |message_value| {
                        if (message_value.isString()) {
                            if (!this.single_line) {
                                this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                            }

                            writer.print(
                                comptime Output.prettyFmt("<r><blue>message<d>:<r> ", enable_ansi_colors),
                                .{},
                            );

                            const tag = try Tag.getAdvanced(message_value, this.globalThis, .{
                                .hide_global = true,
                                .disable_inspect_custom = this.disable_inspect_custom,
                            });
                            try this.format(tag, Writer, writer_, message_value, this.globalThis, enable_ansi_colors);
                            if (this.failed) return;
                            this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                            if (!this.single_line) {
                                writer.writeAll("\n");
                            }
                        }
                    }

                    switch (event_type) {
                        .MessageEvent => {
                            if (!this.single_line) {
                                this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                            }

                            writer.print(
                                comptime Output.prettyFmt("<r><blue>data<d>:<r> ", enable_ansi_colors),
                                .{},
                            );
                            const data: JSValue = (try value.fastGet(.data)) orelse BindingEscape.borrowEngineValue(value, .js_undefined);
                            const tag = try Tag.getAdvanced(data, this.globalThis, .{
                                .hide_global = true,
                                .disable_inspect_custom = this.disable_inspect_custom,
                            });
                            try this.format(tag, Writer, writer_, data, this.globalThis, enable_ansi_colors);
                            if (this.failed) return;
                            this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                            if (!this.single_line) {
                                writer.writeAll("\n");
                            }
                        },
                        .ErrorEvent => {
                            if (try value.fastGet(.@"error")) |error_value| {
                                if (!this.single_line) {
                                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                }

                                writer.print(
                                    comptime Output.prettyFmt("<r><blue>error<d>:<r> ", enable_ansi_colors),
                                    .{},
                                );

                                const tag = try Tag.getAdvanced(error_value, this.globalThis, .{
                                    .hide_global = true,
                                    .disable_inspect_custom = this.disable_inspect_custom,
                                });
                                try this.format(tag, Writer, writer_, error_value, this.globalThis, enable_ansi_colors);
                                if (this.failed) return;
                                this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                                if (!this.single_line) {
                                    writer.writeAll("\n");
                                }
                            }
                        },
                        else => unreachable,
                    }
                }

                if (!this.single_line) {
                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                }
                writer.writeAll("}");
            },
            .JSX => {
                const props = (try value.get("props")) orelse
                    return this.printAs(.Object, Writer, writer_, value, jsType, enable_ansi_colors);
                if (!props.isObject())
                    return this.printAs(.Object, Writer, writer_, value, jsType, enable_ansi_colors);

                writer.writeAll(comptime Output.prettyFmt("<r>", enable_ansi_colors));

                writer.writeAll("<");

                var needs_space = false;
                var tag_name_str: bun.TextView = .empty;
                var tag_name_owned = bun.String.empty;
                defer tag_name_owned.deref();

                var tag_name_slice: bun.String.Slice = bun.String.Slice.empty;
                var is_tag_kind_primitive = false;

                defer tag_name_slice.deinit();

                if (try value.get("type")) |type_value| {
                    const _tag = try Tag.getAdvanced(type_value, this.globalThis, .{
                        .hide_global = true,
                        .disable_inspect_custom = this.disable_inspect_custom,
                    });

                    if (_tag.cell == .Symbol) {} else if (_tag.cell.isStringLike()) {
                        tag_name_owned = try type_value.toBunString();
                        tag_name_str = tag_name_owned.textView();
                        is_tag_kind_primitive = true;
                    } else if (_tag.cell.isObject() or type_value.isCallable()) {
                        tag_name_owned = try type_value.getDeclaredName();
                        tag_name_str = tag_name_owned.textView();
                        if (tag_name_str.isEmpty()) {
                            tag_name_str = .{ .latin1 = "NoName" };
                        }
                    } else {
                        tag_name_owned = try type_value.toBunString();
                        tag_name_str = tag_name_owned.textView();
                    }

                    tag_name_slice = try tag_name_str.toSlice(default_allocator);
                    needs_space = true;
                } else {
                    tag_name_slice = .fromUTF8NeverFree("unknown");

                    needs_space = true;
                }

                if (!is_tag_kind_primitive)
                    writer.writeAll(comptime Output.prettyFmt("<cyan>", enable_ansi_colors))
                else
                    writer.writeAll(comptime Output.prettyFmt("<green>", enable_ansi_colors));
                writer.writeAll(tag_name_slice.slice());
                if (enable_ansi_colors) writer.writeAll(comptime Output.prettyFmt("<r>", enable_ansi_colors));

                if (try value.get("key")) |key_value| {
                    if (!key_value.isUndefinedOrNull()) {
                        if (needs_space)
                            writer.writeAll(" key=")
                        else
                            writer.writeAll("key=");

                        const old_quote_strings = this.quote_strings;
                        this.quote_strings = true;
                        defer this.quote_strings = old_quote_strings;

                        try this.format(try Tag.getAdvanced(key_value, this.globalThis, .{
                            .hide_global = true,
                            .disable_inspect_custom = this.disable_inspect_custom,
                        }), Writer, writer_, key_value, this.globalThis, enable_ansi_colors);

                        needs_space = true;
                    }
                }

                {
                    const prev_quote_strings = this.quote_strings;
                    defer this.quote_strings = prev_quote_strings;
                    this.quote_strings = true;

                    const property_scope = value;
                    var props_root = try props.toRoot();
                    defer props_root.deinit();
                    var props_iter = try jsc.JSPropertyIterator(.{
                        .skip_empty_name = true,
                    }).init(&property_scope, &props_root);
                    defer props_iter.deinit();

                    const children_prop = try props.get("children");
                    if (props_iter.len > 0) {
                        {
                            this.indent += 1;
                            defer this.indent -|= 1;
                            const count_without_children = props_iter.len - @as(usize, @intFromBool(children_prop != null));

                            while (try props_iter.next(&property_scope)) |next_entry| {
                                var entry = next_entry;
                                const prop = entry.name.takeBunString();
                                defer prop.deref();
                                if (prop.eqlComptime("children"))
                                    continue;

                                const property_value = entry.value.operand(&property_scope).asEngine();
                                const tag = try Tag.getAdvanced(property_value, this.globalThis, .{
                                    .hide_global = true,
                                    .disable_inspect_custom = this.disable_inspect_custom,
                                });

                                if (tag.cell.isHidden()) continue;

                                if (needs_space) writer.space();
                                needs_space = false;

                                writer.print(
                                    comptime Output.prettyFmt("<r><blue>{f}<d>=<r>", enable_ansi_colors),
                                    .{prop.trunc(128)},
                                );

                                if (tag.cell.isStringLike()) {
                                    if (comptime enable_ansi_colors) {
                                        writer.writeAll(comptime Output.prettyFmt("<r><green>", true));
                                    }
                                }

                                try this.format(tag, Writer, writer_, property_value, this.globalThis, enable_ansi_colors);

                                if (tag.cell.isStringLike()) {
                                    if (comptime enable_ansi_colors) {
                                        writer.writeAll(comptime Output.prettyFmt("<r>", true));
                                    }
                                }

                                if (!this.single_line and (
                                    // count_without_children is necessary to prevent printing an extra newline
                                    // if there are children and one prop and the child prop is the last prop
                                    props_iter.i + 1 < count_without_children and
                                        // 3 is arbitrary but basically
                                        //  <input type="text" value="foo" />
                                        //  ^ should be one line
                                        // <input type="text" value="foo" bar="true" baz={false} />
                                        //  ^ should be multiple lines
                                        props_iter.i > 3))
                                {
                                    writer.writeAll("\n");
                                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                } else if (props_iter.i + 1 < count_without_children) {
                                    writer.space();
                                }
                            }
                        }

                        if (children_prop) |children| {
                            const tag = try Tag.get(children, this.globalThis);

                            const print_children = switch (tag.tag) {
                                .String, .JSX, .Array => true,
                                else => false,
                            };

                            if (print_children and !this.single_line) {
                                print_children: {
                                    switch (tag.tag) {
                                        .String => {
                                            var children_string_owned = try children.toBunString();
                                            defer children_string_owned.deref();
                                            const children_string = children_string_owned.textView();
                                            if (children_string.isEmpty()) break :print_children;
                                            if (comptime enable_ansi_colors) writer.writeAll(comptime Output.prettyFmt("<r>", true));

                                            writer.writeAll(">");
                                            if (children_string.len() < 128) {
                                                writer.writeString(children_string);
                                            } else {
                                                {
                                                    this.indent += 1;
                                                    defer this.indent -|= 1;
                                                    writer.writeAll("\n");
                                                    this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                                }
                                                writer.writeString(children_string);
                                                writer.writeAll("\n");
                                                this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                            }
                                        },
                                        .JSX => {
                                            writer.writeAll(">\n");

                                            {
                                                this.indent += 1;
                                                defer this.indent -|= 1;
                                                this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                                try this.format(try Tag.get(children, this.globalThis), Writer, writer_, children, this.globalThis, enable_ansi_colors);
                                            }

                                            writer.writeAll("\n");
                                            this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                        },
                                        .Array => {
                                            const length = try children.getLength();
                                            if (length == 0) break :print_children;
                                            writer.writeAll(">\n");

                                            {
                                                this.indent += 1;
                                                defer this.indent -|= 1;
                                                this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                                const _prev_quote_strings = this.quote_strings;
                                                this.quote_strings = false;
                                                defer this.quote_strings = _prev_quote_strings;

                                                var j: usize = 0;
                                                while (j < length) : (j += 1) {
                                                    const child = try children.getIndex(j);
                                                    try this.format(try Tag.getAdvanced(child, this.globalThis, .{
                                                        .hide_global = true,
                                                        .disable_inspect_custom = this.disable_inspect_custom,
                                                    }), Writer, writer_, child, this.globalThis, enable_ansi_colors);
                                                    if (j + 1 < length) {
                                                        writer.writeAll("\n");
                                                        this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                                    }
                                                }
                                            }

                                            writer.writeAll("\n");
                                            this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                                        },
                                        else => unreachable,
                                    }

                                    writer.writeAll("</");
                                    if (!is_tag_kind_primitive)
                                        writer.writeAll(comptime Output.prettyFmt("<r><cyan>", enable_ansi_colors))
                                    else
                                        writer.writeAll(comptime Output.prettyFmt("<r><green>", enable_ansi_colors));
                                    writer.writeAll(tag_name_slice.slice());
                                    if (enable_ansi_colors) writer.writeAll(comptime Output.prettyFmt("<r>", enable_ansi_colors));
                                    writer.writeAll(">");
                                }

                                return;
                            }
                        }
                    }
                }

                writer.writeAll(" />");
            },
            .Object => {
                bun.assert(value.isCell());
                const prev_quote_strings = this.quote_strings;
                this.quote_strings = true;
                defer this.quote_strings = prev_quote_strings;

                const Iterator = PropertyIterator(Writer, enable_ansi_colors);

                // We want to figure out if we should print this object
                // on one line or multiple lines
                //
                // The 100% correct way would be to print everything to
                // a temporary buffer and then check how long each line was
                //
                // But it's important that console.log() is fast. So we
                // do a small compromise to avoid multiple passes over input
                //
                // We say:
                //
                //   If the object has at least 2 properties and ANY of the following conditions are met:
                //      - total length of all the property names is more than
                //        14 characters
                //     - the parent object is printing each property on a new line
                //     - The first property is a DOM object, ESM namespace, Map, Set, or Blob
                //
                //   Then, we print it each property on a new line, recursively.
                //
                const prev_always_newline_scope = this.always_newline_scope;
                defer this.always_newline_scope = prev_always_newline_scope;
                var iter = Iterator{
                    .formatter = this,
                    .writer = writer_,
                    .always_newline = !this.single_line and (this.always_newline_scope or this.goodTimeForANewLine()),
                    .single_line = this.single_line,
                    .parent = value,
                };

                if (this.depth > this.max_depth) {
                    if (this.single_line) {
                        writer.writeAll(" ");
                    } else if (this.always_newline_scope or this.goodTimeForANewLine()) {
                        writer.writeAll("\n");
                        this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                        this.resetLine();
                    }

                    var display_name = try value.getName();
                    if (display_name.isEmpty()) {
                        display_name = String.static("Object");
                    }
                    writer.print(comptime Output.prettyFmt("<r><cyan>[{f} ...]<r>", enable_ansi_colors), .{
                        display_name,
                    });
                    return;
                } else if (this.ordered_properties) {
                    try value.forEachPropertyOrdered(&iter, Iterator.forEach);
                } else {
                    try value.forEachProperty(&iter, Iterator.forEach);
                }

                if (this.failed) return;

                if (iter.i == 0) {
                    if (value.isClass())
                        try this.printAs(.Class, Writer, writer_, value, jsType, enable_ansi_colors)
                    else if (value.isCallable())
                        try this.printAs(.Function, Writer, writer_, value, jsType, enable_ansi_colors)
                    else {
                        if (try getObjectName(value)) |name_str| {
                            defer name_str.deref();
                            writer.print("{f} ", .{name_str});
                        }
                        writer.writeAll("{}");
                    }
                } else {
                    this.depth -= 1;

                    if (iter.always_newline) {
                        this.indent -|= 1;
                        this.printComma(Writer, writer_, enable_ansi_colors) catch return this.recordWriteFailure();
                        writer.writeAll("\n");
                        this.writeIndent(Writer, writer_) catch return this.recordWriteFailure();
                        writer.writeAll("}");
                        this.estimated_line_length += 1;
                    } else {
                        this.estimated_line_length += 2;
                        writer.writeAll(" }");
                    }
                }
            },
            .TypedArray => {
                var arrayBuffer = (try value.copyArrayBufferView()).?;
                defer arrayBuffer.deinit();
                const slice = arrayBuffer.mutableSlice();
                const element_length = if (jsType.typedArrayElementSize()) |bytes_per_element|
                    slice.len / bytes_per_element
                else
                    slice.len;

                if (this.format_buffer_as_text and jsType == .Uint8Array and bun.strings.isValidUTF8(slice)) {
                    if (comptime enable_ansi_colors) {
                        writer.writeAll(Output.prettyFmt("<r><green>", true));
                    }
                    JSPrinter.writeJSONString(slice, Writer, writer_, .utf8) catch return this.recordWriteFailure();
                    if (comptime enable_ansi_colors) {
                        writer.writeAll(Output.prettyFmt("<r>", true));
                    }
                    return;
                }

                writer.writeAll(
                    if (jsType == .Uint8Array and
                        try value.isBuffer())
                        "Buffer"
                    else if (jsType == .ArrayBuffer and value.arrayBufferIsShared())
                        "SharedArrayBuffer"
                    else
                        bun.asByteSlice(@tagName(jsType)),
                );
                if (slice.len == 0) {
                    writer.print("({d}) []", .{element_length});
                    return;
                }

                writer.print("({d}) [ ", .{element_length});

                switch (jsType) {
                    .Int8Array => this.writeTypedArray(
                        *@TypeOf(writer),
                        &writer,
                        i8,
                        @alignCast(std.mem.bytesAsSlice(i8, slice)),
                        enable_ansi_colors,
                    ),
                    .Int16Array => this.writeTypedArray(
                        *@TypeOf(writer),
                        &writer,
                        i16,
                        @alignCast(std.mem.bytesAsSlice(i16, slice)),
                        enable_ansi_colors,
                    ),
                    .Uint16Array => this.writeTypedArray(
                        *@TypeOf(writer),
                        &writer,
                        u16,
                        @alignCast(std.mem.bytesAsSlice(u16, slice)),
                        enable_ansi_colors,
                    ),
                    .Int32Array => this.writeTypedArray(
                        *@TypeOf(writer),
                        &writer,
                        i32,
                        @alignCast(std.mem.bytesAsSlice(i32, slice)),
                        enable_ansi_colors,
                    ),
                    .Uint32Array => this.writeTypedArray(
                        *@TypeOf(writer),
                        &writer,
                        u32,
                        @alignCast(std.mem.bytesAsSlice(u32, slice)),
                        enable_ansi_colors,
                    ),
                    .Float16Array => this.writeTypedArray(
                        *@TypeOf(writer),
                        &writer,
                        f16,
                        @alignCast(std.mem.bytesAsSlice(f16, slice)),
                        enable_ansi_colors,
                    ),
                    .Float32Array => this.writeTypedArray(
                        *@TypeOf(writer),
                        &writer,
                        f32,
                        @alignCast(std.mem.bytesAsSlice(f32, slice)),
                        enable_ansi_colors,
                    ),
                    .Float64Array => this.writeTypedArray(
                        *@TypeOf(writer),
                        &writer,
                        f64,
                        @alignCast(std.mem.bytesAsSlice(f64, slice)),
                        enable_ansi_colors,
                    ),
                    .BigInt64Array => this.writeTypedArray(
                        *@TypeOf(writer),
                        &writer,
                        i64,
                        @alignCast(std.mem.bytesAsSlice(i64, slice)),
                        enable_ansi_colors,
                    ),
                    .BigUint64Array => {
                        this.writeTypedArray(
                            *@TypeOf(writer),
                            &writer,
                            u64,
                            @as([]align(std.meta.alignment([]u64)) u64, @alignCast(std.mem.bytesAsSlice(u64, slice))),
                            enable_ansi_colors,
                        );
                    },

                    // Uint8Array, Uint8ClampedArray, DataView, ArrayBuffer
                    else => this.writeTypedArray(*@TypeOf(writer), &writer, u8, slice, enable_ansi_colors),
                }

                writer.writeAll(" ]");
            },
            .RevokedProxy => {
                this.addForNewLine("<Revoked Proxy>".len);
                writer.print(comptime Output.prettyFmt("<r><cyan>\\<Revoked Proxy\\><r>", enable_ansi_colors), .{});
            },
            .Proxy => {
                const target = (try value.getProxyInternalField(.target)).?;
                if (Environment.allow_assert) {
                    // Proxy does not allow non-objects here.
                    bun.assert(target.isCell());
                }
                // TODO: if (options.showProxy), print like `Proxy { target: ..., handlers: ... }`
                // this is default off so it is not used.
                try this.format(try ConsoleObject.Formatter.Tag.get(target, this.globalThis), Writer, writer_, target, this.globalThis, enable_ansi_colors);
            },
        }
    }

    fn writeTypedArray(this: *ConsoleObject.Formatter, comptime WriterWrapped: type, writer: WriterWrapped, comptime Number: type, slice: []const Number, comptime enable_ansi_colors: bool) void {
        const fmt_ = if (Number == i64 or Number == u64)
            "<r><yellow>{d}n<r>"
        else if (@typeInfo(Number) == .float)
            "<r><yellow>{f}<r>"
        else
            "<r><yellow>{d}<r>";
        const more = if (Number == i64 or Number == u64)
            "<r><d>n, ... {d} more<r>"
        else
            "<r><d>, ... {d} more<r>";

        writer.print(comptime Output.prettyFmt(fmt_, enable_ansi_colors), .{
            if (@typeInfo(Number) == .float) bun.fmt.double(@floatCast(slice[0])) else slice[0],
        });
        var leftover = slice[1..];
        const max = 512;
        leftover = leftover[0..@min(leftover.len, max)];
        for (leftover) |el| {
            this.printComma(@TypeOf(writer.ctx), writer.ctx, enable_ansi_colors) catch return this.recordWriteFailure();
            writer.space();

            writer.print(comptime Output.prettyFmt(fmt_, enable_ansi_colors), .{
                if (@typeInfo(Number) == .float) bun.fmt.double(@floatCast(el)) else el,
            });
        }

        if (slice.len > max + 1) {
            writer.print(comptime Output.prettyFmt(more, enable_ansi_colors), .{slice.len - max - 1});
        }
    }

    pub fn format(this: *ConsoleObject.Formatter, result: Tag.Result, comptime Writer: type, writer: *std.Io.Writer, value: JSValue, globalThis: *JSGlobalObject, comptime enable_ansi_colors: bool) bun.JSError!void {
        const prevGlobalThis = this.globalThis;
        defer this.globalThis = prevGlobalThis;
        this.globalThis = globalThis;

        // This looks incredibly redundant. We make the ConsoleObject.Formatter.Tag a
        // comptime var so we have to repeat it here. The rationale there is
        // it _should_ limit the stack usage because each version of the
        // function will be relatively small
        switch (result.tag.tag()) {
            inline else => |tag| try this.printAs(tag, Writer, writer, value, result.cell, enable_ansi_colors),

            .CustomFormattedObject => {
                this.custom_formatted_object = result.tag.CustomFormattedObject;
                try this.printAs(.CustomFormattedObject, Writer, writer, value, result.cell, enable_ansi_colors);
            },
        }
    }
};

pub fn count(globalThis: *JSGlobalObject, label: []const u8) bun.OOM!void {
    var this = globalThis.bunVM().console;
    const hash = bun.hash(label);
    // we don't want to store these strings, it will take too much memory
    const counter = try this.counts.getOrPut(globalThis.allocator(), hash);
    const current = @as(u32, if (counter.found_existing) counter.value_ptr.* else @as(u32, 0)) + 1;
    counter.value_ptr.* = current;

    const writer = this.writer;
    if (Output.enable_ansi_colors_stdout)
        writer.print(comptime Output.prettyFmt("<r>{s}<d>: <r><yellow>{d}<r>\n", true), .{ label, current }) catch return
    else
        writer.print(comptime Output.prettyFmt("<r>{s}<d>: <r><yellow>{d}<r>\n", false), .{ label, current }) catch return;
    writer.flush() catch {};
}
pub fn countReset(globalThis: *JSGlobalObject, hash: u64) void {
    var this = globalThis.bunVM().console;
    // we don't delete it because deleting is implemented via tombstoning
    const entry = this.counts.getEntry(hash) orelse return;
    entry.value_ptr.* = 0;
}

const PendingTimers = std.AutoHashMap(u64, ?SystemTimer);
threadlocal var pending_time_logs: PendingTimers = undefined;
threadlocal var pending_time_logs_loaded = false;

fn time(id: u64) bun.OOM!void {
    if (!pending_time_logs_loaded) {
        pending_time_logs = PendingTimers.init(default_allocator);
        pending_time_logs_loaded = true;
    }

    const result = try pending_time_logs.getOrPut(id);

    if (!result.found_existing or (result.found_existing and result.value_ptr.* == null)) {
        result.value_ptr.* = SystemTimer.start() catch unreachable;
    }
}
fn timeEnd(label_value: bun.bindgen.DOMStringView) bun.OOM!void {
    if (!pending_time_logs_loaded) {
        return;
    }

    const timer = pending_time_logs.getPtr(label_value.hashUTF8()) orelse return;
    var value: SystemTimer = timer.* orelse return;
    const utf8 = try label_value.toUTF8(bun.default_allocator);
    defer utf8.deinit();
    const label = utf8.slice();
    timer.* = null;
    // get the duration in microseconds
    // then display it in milliseconds
    Output.printElapsed(@as(f64, @floatFromInt(value.read() / std.time.ns_per_us)) / std.time.us_per_ms);
    switch (label.len) {
        0 => Output.printErrorln("\n", .{}),
        else => Output.printErrorln(" {s}", .{label}),
    }

    Output.flush();
}

pub fn timeLog(
    global: *JSGlobalObject,
    label: []const u8,
    args: []const JSValue,
) bun.JSError!void {
    if (!pending_time_logs_loaded) {
        return;
    }

    const id = bun.hash(label);
    var value: SystemTimer = (pending_time_logs.get(id) orelse return) orelse return;
    // get the duration in microseconds
    // then display it in milliseconds
    Output.printElapsed(@as(f64, @floatFromInt(value.read() / std.time.ns_per_us)) / std.time.us_per_ms);
    switch (label.len) {
        0 => {},
        else => Output.printError(" {s}", .{label}),
    }
    Output.flush();

    // print the arguments
    var fmt = ConsoleObject.Formatter{
        .remaining_values = &[_]JSValue{},
        .globalThis = global,
        .ordered_properties = false,
        .quote_strings = false,
        .max_depth = blk: {
            const cli_context = CLI.get();
            break :blk cli_context.runtime_options.console_depth orelse DEFAULT_CONSOLE_LOG_DEPTH;
        },
        .stack_check = bun.StackCheck.init(),
        .can_throw_stack_overflow = true,
    };
    const console = global.bunVM().console;
    const writer = console.error_writer;
    const Writer = @TypeOf(writer);
    for (args) |arg| {
        const tag = try ConsoleObject.Formatter.Tag.get(arg, global);
        _ = writer.write(" ") catch 0;
        if (Output.enable_ansi_colors_stderr) {
            try fmt.format(tag, Writer, writer, arg, global, true);
        } else {
            try fmt.format(tag, Writer, writer, arg, global, false);
        }
    }
    _ = writer.write("\n") catch 0;
    writer.flush() catch {};
}

fn copyCallScopedValues(
    context: anytype,
    values: anytype,
    output: *[255]JSValue,
) []const JSValue {
    const length = @min(values.len(), output.len);
    for (0..length) |index| output[index] = values.at(index).?.operand(context).asEngine();
    return output[0..length];
}

fn rawValue(value: JSValue) jsc.JSValue {
    return BindingEscape.rawCallScopedValue(value, value.engineView());
}

pub fn formatScopedValue(context: anytype, value: bun.bindgen.EngineValueView, level: MessageLevel, writer: *std.Io.Writer, options: FormatOptions) FormatError!void {
    const global = context.viewToken().globalObject();
    const raw = value.operand(context).asEngine();
    try format2(level, global, (&raw)[0..1].ptr, 1, writer, options);
}

fn formatOperand(
    raw: JSValue,
    options: FormatOptions,
) bun.JSError!bun.bindgen.DOMString {
    const globalThis = raw.viewToken().globalObject();
    var output = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer output.deinit();
    format2(.Debug, globalThis, (&raw)[0..1].ptr, 1, &output.writer, options) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |js_error| return js_error,
    };
    output.writer.flush() catch return error.OutOfMemory;
    return bun.bindgen.DOMString.fromUTF8(output.written());
}

fn formatCallScopedTable(
    context: anytype,
    value: anytype,
    properties: anytype,
    options: FormatOptions,
) bun.JSError!bun.bindgen.DOMString {
    const globalThis = context.viewToken().globalObject();
    const raw_value = value.operand(context).asEngine();
    const raw_properties = if (properties) |property_values| property_values.operand(context).asEngine() else null;
    var output = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer output.deinit();
    var printer = try TablePrinter.init(globalThis, .Log, raw_value, raw_properties);
    defer printer.value_formatter.deinit();
    printer.value_formatter.max_depth = options.max_depth;
    printer.value_formatter.ordered_properties = options.ordered_properties;
    printer.value_formatter.single_line = options.single_line;
    switch (options.enable_colors) {
        inline else => |colors| printer.printTable(*std.Io.Writer, &output.writer, colors) catch |err| {
            try checkMemoryFormatFailure(&printer.value_formatter);
            return switch (err) {
                error.WriteFailed => error.OutOfMemory,
                else => |failure| failure,
            };
        },
    }
    try checkMemoryFormatFailure(&printer.value_formatter);
    output.writer.flush() catch return error.OutOfMemory;
    return bun.bindgen.DOMString.fromUTF8(output.written());
}

fn formatCallScopedValueForError(context: anytype, value: anytype) bun.JSError!bun.bindgen.DOMString {
    const globalThis = context.viewToken().globalObject();
    const raw = value.operand(context).asEngine();
    var output = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer output.deinit();
    var formatter = Formatter{
        .globalThis = globalThis,
        .remaining_values = &.{raw},
        .can_throw_stack_overflow = true,
    };
    defer formatter.deinit();
    try formatter.format(try Formatter.Tag.get(raw, globalThis), *std.Io.Writer, &output.writer, raw, globalThis, false);
    try checkMemoryFormatFailure(&formatter);
    output.writer.flush() catch return error.OutOfMemory;
    return bun.bindgen.DOMString.fromUTF8(output.written());
}

fn printCallScopedLog(context: anytype, value: anytype, level: MessageLevel) void {
    const globalThis = context.viewToken().globalObject();
    const raw = value.operand(context).asEngine();
    messageWithTypeAndLevel(.Log, level, globalThis, &.{raw});
}

pub fn printOwnedEngineValue(global: *JSGlobalObject, value: *const bun.bindgen.EngineRoot) void {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const raw = value.operand(&scope);
    messageWithTypeAndLevel(.Log, .Log, scope.viewToken().globalObject(), &.{raw});
}

pub fn formatOwnedBranded(
    _: *JSGlobalObject,
    value: anytype,
    options: FormatOptions,
) bun.JSError!bun.bindgen.DOMString {
    const Value = switch (@typeInfo(@TypeOf(value))) {
        .pointer => |pointer| pointer.child,
        else => @compileError("console formatting requires a pointer to an owned branded value"),
    };
    if (comptime !@hasDecl(Value, "bindgen_owned_branded_value")) {
        @compileError("console formatting requires an owned branded value");
    }
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    value.initScope(&scope);
    defer scope.deinit();
    return formatOperand(
        value.operand(&scope).asEngine(),
        options,
    );
}

pub fn formatClassRefForBinding(context: anytype, args: anytype) bun.JSError!bun.bindgen.DOMString {
    const global = context.viewToken().globalObject();
    var reference = try args.bindingThis.toOwned();
    defer reference.deinit();
    var output = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer output.deinit();
    var formatter = Formatter{
        .globalThis = global,
        .stack_check = bun.StackCheck.init(),
        .can_throw_stack_overflow = true,
    };
    defer formatter.deinit();
    var colors = false;
    if (args.options) |config| {
        if (config.depth) |depth| formatter.max_depth = depth;
        if (config.colors) |enabled| colors = enabled;
        if (config.sorted) |sorted| formatter.ordered_properties = sorted;
        if (config.compact) |compact| formatter.single_line = compact;
    }
    if (args.depth) |depth| {
        if (depth < 0) {
            formatter.max_depth = 0;
            formatter.depth = 1;
        } else {
            formatter.max_depth = @intCast(@min(depth, std.math.maxInt(u16)));
        }
    }
    switch (colors) {
        inline else => |enabled| try formatter.printClassRef(&output.writer, &reference, enabled),
    }
    try checkMemoryFormatFailure(&formatter);
    output.writer.flush() catch return error.OutOfMemory;
    return bun.bindgen.DOMString.fromUTF8(output.written());
}

pub fn formatValueForBinding(context: anytype, value: anytype, options: FormatOptions) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return formatOperand(value.operand(context).asEngine(), options);
}

pub fn formatTableForBinding(context: anytype, value: InspectTableObjectView, properties: ?InspectTablePropertiesView, options: FormatOptions) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return formatCallScopedTable(context, value, properties, options);
}

pub fn formatValueForErrorBinding(context: anytype, value: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return formatCallScopedValueForError(context, value);
}

pub fn printLogForBinding(context: anytype, value: anytype) void {
    printCallScopedLog(context, value, .Log);
}

fn bindMessageWithTypeAndLevel(
    context: bun.bindgen.CallContext(MessageWithTypeAndLevelSchema),
    args: bun.bindgen.Args(MessageWithTypeAndLevelSchema),
) bun.JSError!bun.bindgen.Return(MessageWithTypeAndLevelSchema) {
    const global = context.viewToken().globalObject();
    var raw_values: [255]JSValue = undefined;
    return messageWithTypeAndLevel_(
        @fromBackingInt(args.messageType),
        @fromBackingInt(args.messageLevel),
        global,
        copyCallScopedValues(context, args.values, &raw_values),
    );
}

fn bindTimeLog(
    context: bun.bindgen.CallContext(TimeLogSchema),
    args: bun.bindgen.Args(TimeLogSchema),
) bun.JSError!bun.bindgen.Return(TimeLogSchema) {
    const global = context.viewToken().globalObject();
    const label = try args.label.toUTF8(bun.default_allocator);
    defer label.deinit();
    var raw_values: [255]JSValue = undefined;
    return timeLog(global, label.slice(), copyCallScopedValues(context, args.values, &raw_values));
}

fn bindCount(
    context: bun.bindgen.CallContext(CountSchema),
    args: bun.bindgen.Args(CountSchema),
) bun.JSError!bun.bindgen.Return(CountSchema) {
    const label = try args.label.toUTF8(bun.default_allocator);
    defer label.deinit();
    try count(context.viewToken().globalObject(), label.slice());
}

fn bindCountReset(
    context: bun.bindgen.CallContext(CountResetSchema),
    args: bun.bindgen.Args(CountResetSchema),
) bun.bindgen.Return(CountResetSchema) {
    countReset(context.viewToken().globalObject(), args.label.hashUTF8());
}

fn bindTime(
    _: bun.bindgen.CallContext(TimeSchema),
    args: bun.bindgen.Args(TimeSchema),
) bun.JSError!bun.bindgen.Return(TimeSchema) {
    try time(args.label.hashUTF8());
}

fn bindTimeEnd(
    _: bun.bindgen.CallContext(TimeEndSchema),
    args: bun.bindgen.Args(TimeEndSchema),
) bun.JSError!bun.bindgen.Return(TimeEndSchema) {
    try timeEnd(args.label);
}

fn bindTakeHeapSnapshot(
    context: bun.bindgen.CallContext(TakeHeapSnapshotSchema),
    _: bun.bindgen.Args(TakeHeapSnapshotSchema),
) bun.bindgen.Return(TakeHeapSnapshotSchema) {
    const global = context.viewToken().globalObject();
    const snapshot = context.engineIn("heap_profiling", "generateHeapSnapshot").call(.{}) catch |err|
        return global.reportActiveExceptionAsUnhandled(err);
    printCallScopedLog(context, snapshot.operand(context).engineView(), .Debug);
}

comptime {
    _ = MessageWithTypeAndLevelBinding;
    _ = TimeLogBinding;
    _ = CountBinding;
    _ = CountResetBinding;
    _ = TimeBinding;
    _ = TimeEndBinding;
    _ = TakeHeapSnapshotBinding;
}

const string = []const u8;

const std = @import("std");
const SystemTimer = @import("../perf/system_timer.zig").Timer;
const CLI = @import("../cli/cli.zig").Command;
pub const PrettyFormatEngine = @import("../test_runner/PrettyFormatEngine.zig");
const JestPrettyFormat = PrettyFormatEngine.JestPrettyFormat;
const Headers = @import("../runtime/webcore/Headers.zig");

const bun = @import("bun");
const Environment = bun.Environment;
const JSLexer = bun.js_lexer;
const JSPrinter = bun.js_printer;
const Output = bun.Output;
const String = bun.String;
const default_allocator = bun.default_allocator;
const strings = bun.strings;

const jsc = bun.jsc;
const EventType = jsc.EventType;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = bun.bindgen.EngineOperand;
const VirtualMachine = jsc.VirtualMachine;
const CallCustomInspectFunctionSchema = ConsoleObjectBindings.engineShim("callCustomInspectFunction");
const PropertyAccessorBindings = bun.bindgen.Module("property_accessors");
const InspectGetterSetterSchema = PropertyAccessorBindings.engineShim("inspectGetterSetter");
const InspectCustomGetterSetterSchema = PropertyAccessorBindings.engineShim("inspectCustomGetterSetter");
const CountSchema = ConsoleObjectBindings.nativeExport("consoleCount");
const CountResetSchema = ConsoleObjectBindings.nativeExport("consoleCountReset");
const TimeSchema = ConsoleObjectBindings.nativeExport("consoleTime");
const TimeEndSchema = ConsoleObjectBindings.nativeExport("consoleTimeEnd");
const TakeHeapSnapshotSchema = ConsoleObjectBindings.nativeExport("consoleTakeHeapSnapshot");
const CountBinding = bun.bindgen.Fn(CountSchema, bindCount);
const CountResetBinding = bun.bindgen.Fn(CountResetSchema, bindCountReset);
const TimeBinding = bun.bindgen.Fn(TimeSchema, bindTime);
const TimeEndBinding = bun.bindgen.Fn(TimeEndSchema, bindTimeEnd);
const TakeHeapSnapshotBinding = bun.bindgen.Fn(TakeHeapSnapshotSchema, bindTakeHeapSnapshot);
const ConsoleObjectBindings = bun.bindgen.Module("ConsoleObject");
const MessageWithTypeAndLevelSchema = ConsoleObjectBindings.nativeExport("messageWithTypeAndLevel");
const TimeLogSchema = ConsoleObjectBindings.nativeExport("timeLog");
const MessageWithTypeAndLevelBinding = bun.bindgen.Fn(MessageWithTypeAndLevelSchema, bindMessageWithTypeAndLevel);
const TimeLogBinding = bun.bindgen.Fn(TimeLogSchema, bindTimeLog);
const BunObjectBindings = bun.bindgen.Module("BunObject");
const BunInspectTableSchema = BunObjectBindings.function("inspectTable");
const BunInspectTableArgs = bun.bindgen.Args(BunInspectTableSchema);
const InspectTableValue = @typeInfo(@FieldType(BunInspectTableArgs, "value")).optional.child;
const InspectTableObjectView = @FieldType(InspectTableValue, "object");
const InspectTablePropertiesOrOptions = @typeInfo(@FieldType(BunInspectTableArgs, "properties_or_options")).optional.child;
const InspectTablePropertiesView = @FieldType(InspectTablePropertiesOrOptions, "properties");
