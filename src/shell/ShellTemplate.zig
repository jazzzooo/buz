pub fn appendCommandFromBinding(
    context: anytype,
    string_args: anytype,
    template_args: anytype,
    out_values: ?*std.array_list.Managed(ShellValue.Value),
    object_count: *u32,
    jsstrings: *std.array_list.Managed(bun.String),
    out_script: *std.array_list.Managed(u8),
) bun.bindgen.CallError(@TypeOf(context))!void {
    var builder = shell.ShellSrcBuilder.init(out_script, jsstrings);
    var jsobjref_buf: [128]u8 = @splat(0);

    const last = string_args.len() -| 1;
    for (0..string_args.len()) |index| {
        var owned_string = string_args.at(index).?.toOwned();
        var string = owned_string.takeBunString();
        defer string.deref();
        if (!try builder.appendBunStr(string, false)) {
            return failBinding(context, .parse, "Shell script string contains invalid UTF-16", .{});
        }
        if (index < last) {
            const template_value = template_args.at(index) orelse {
                return failBinding(context, .invalid_argument, "Shell script is missing an interpolated value", .{});
            };
            try appendTemplateValue(context, template_value.atoms, out_values, object_count, out_script, jsstrings, jsobjref_buf[0..]);
        }
    }
}

fn appendTemplateValue(
    context: anytype,
    atoms: anytype,
    out_values: ?*std.array_list.Managed(ShellValue.Value),
    object_count: *u32,
    out_script: *std.array_list.Managed(u8),
    jsstrings: *std.array_list.Managed(bun.String),
    jsobjref_buf: []u8,
) bun.bindgen.CallError(@TypeOf(context))!void {
    var builder = shell.ShellSrcBuilder.init(out_script, jsstrings);
    for (0..atoms.len()) |index| {
        const atom = atoms.at(index).?;
        switch (atom.kind) {
            .escaped_text, .raw_text => {
                var owned_text = atom.text.toOwned();
                var text = owned_text.takeBunString();
                defer text.deref();
                if (text.indexOfAsciiChar(0) != null) {
                    return failBinding(
                        context,
                        .invalid_argument,
                        "The shell argument must be a string without null bytes. Received \"{f}\"",
                        .{text},
                    );
                }
                const appended = if (atom.kind == .escaped_text)
                    try builder.appendBunStr(text, true)
                else
                    try builder.appendBunStr(text, false);
                if (!appended) {
                    return failBinding(context, .parse, "Shell script string contains invalid UTF-16", .{});
                }
            },
            .object => {
                const value = atom.value orelse
                    return failBinding(context, .invalid_argument, "Shell object interpolation is missing its value", .{});
                if (value == .blob) {
                    const blob = value.blob.get(bun.webcore.Blob.BlobJSBinding).blob.get();
                    if (blob.storePtr()) |store| {
                        if (store.data == .file and store.data.file.pathlike == .path) {
                            const path = store.data.file.pathlike.path.slice();
                            if (bun.strings.indexOfChar(path, 0) != null) {
                                return failBinding(
                                    context,
                                    .invalid_argument,
                                    "The shell argument must be a string without null bytes. Received {f}",
                                    .{bun.fmt.quote(path)},
                                );
                            }
                            if (!try builder.appendUTF8(path, true)) {
                                return failBinding(context, .parse, "Shell script string contains invalid UTF-16", .{});
                            }
                            continue;
                        }
                    }
                }

                const object_index = object_count.*;
                const slice = std.fmt.bufPrint(jsobjref_buf, "{s}{d}", .{ shell.LEX_JS_OBJREF_PREFIX, object_index }) catch unreachable;
                try out_script.appendSlice(slice);
                if (out_values) |values| {
                    var owned: ShellValue.Value = switch (value) {
                        .buffer => |buffer| .{ .buffer = try buffer.toOwned() },
                        .blob => |blob| .{ .blob = try blob.get(bun.webcore.Blob.BlobJSBinding).blob.get().dupe() },
                        .response => |response| .{ .response = try response.toOwned() },
                        .stream => |stream| .{ .stream = try stream.toOwned() },
                    };
                    values.append(owned) catch |err| {
                        owned.deinit();
                        return err;
                    };
                }
                object_count.* += 1;
            },
            .separator => try out_script.append(' '),
        }
    }
}

pub fn failBinding(
    context: anytype,
    comptime tag: anytype,
    comptime format: []const u8,
    args: anytype,
) bun.bindgen.CallError(@TypeOf(context)) {
    const message = try std.fmt.allocPrint(bun.default_allocator, format, args);
    defer bun.default_allocator.free(message);
    return context.fail(tag, try bun.bindgen.DOMString.fromUTF8(message));
}

const std = @import("std");
const bun = @import("bun");
const shell = bun.shell;
const ShellValue = @import("./ShellValue.zig");
