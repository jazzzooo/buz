//! Build-time wire ABI verifier: compares metadata compiled from the generated
//! C header by the C++ target compiler against Zig's translated view of every
//! complete wire aggregate.
const std = @import("std");
const wire = @import("binding_wire");

const layout_magic: u64 = 0x42554e4c41594f55;
const layout_version: u64 = 1;

const layout_values = @extern([*]const u64, .{ .name = "bun_bindgen_wire_layout_values" });
const layout_count = @extern(*const u64, .{ .name = "bun_bindgen_wire_layout_count" });

const ExpectedField = struct {
    name: []const u8,
    offset: u64,
};

const ExpectedType = struct {
    name: []const u8,
    size: u64,
    alignment: u64,
    fields: []const ExpectedField,

    fn lessThan(_: void, a: ExpectedType, b: ExpectedType) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }

    fn compareName(name: PackedName, expected: ExpectedType) std.math.Order {
        return name.compare(expected.name);
    }
};

const expected_type_count = expectedTypeCount();
const expected_types = buildExpectedTypes();

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &buffer);
    const out = &stderr.interface;

    const value_count = std.math.cast(usize, layout_count.*) orelse {
        try out.writeAll("wire layout table is too large for this target\n");
        try out.flush();
        return error.WireLayoutMismatch;
    };
    const types_by_name = try init.gpa.dupe(ExpectedType, &expected_types);
    defer init.gpa.free(types_by_name);
    std.sort.pdq(ExpectedType, types_by_name, {}, ExpectedType.lessThan);
    verifyLayout(out, layout_values[0..value_count], types_by_name) catch |err| {
        switch (err) {
            error.MalformedWireLayoutTable => try out.writeAll("wire layout table is malformed\n"),
            error.WireLayoutMismatch => {},
            else => return err,
        }
        try out.flush();
        return error.WireLayoutMismatch;
    };
    try out.flush();
}

fn verifyLayout(out: *std.Io.Writer, values: []const u64, types_by_name: []const ExpectedType) !void {
    var cursor = try tableCursor(values);
    var matched: std.bit_set.Static(expected_type_count) = .empty;
    var entry_count: usize = 0;
    var mismatches: usize = 0;
    while (cursor.values.len != 0) {
        const name = try cursor.readName();
        entry_count += 1;
        const expected: ?ExpectedType = if (std.sort.binarySearch(ExpectedType, types_by_name, name, ExpectedType.compareName)) |index| blk: {
            if (matched.isSet(index)) {
                mismatches += 1;
                try out.writeAll("duplicate wire layout entry: ");
                try name.write(out);
                try out.writeByte('\n');
            }
            matched.set(index);
            break :blk types_by_name[index];
        } else blk: {
            mismatches += 1;
            try out.writeAll("clang emitted an unknown wire layout entry for ");
            try name.write(out);
            try out.writeByte('\n');
            break :blk null;
        };
        try compareEntry(out, &mismatches, &cursor, expected);
    }
    if (entry_count != types_by_name.len) {
        mismatches += 1;
        try out.print(
            "wire layout type count mismatch: clang emitted {d}, Zig translated {d}\n",
            .{ entry_count, types_by_name.len },
        );
    }
    for (types_by_name, 0..) |expected, index| {
        if (matched.isSet(index)) continue;
        mismatches += 1;
        try out.print("missing clang wire layout entry for {s}\n", .{expected.name});
    }

    if (mismatches != 0) {
        try out.print("wire layout verification failed with {d} mismatches\n", .{mismatches});
        return error.WireLayoutMismatch;
    }
}

fn expectedTypeCount() usize {
    @setEvalBranchQuota(10_000_000);
    var count: usize = 0;
    for (std.meta.declarations(wire)) |name| {
        if (isWireAggregateDeclaration(name)) count += 1;
    }
    return count;
}

fn buildExpectedTypes() [expected_type_count]ExpectedType {
    @setEvalBranchQuota(10_000_000);
    var result: [expected_type_count]ExpectedType = undefined;
    var index: usize = 0;
    for (std.meta.declarations(wire)) |name| {
        if (!isWireAggregateDeclaration(name)) continue;
        const Type = @field(wire, name);
        result[index] = .{
            .name = name,
            .size = @sizeOf(Type),
            .alignment = @alignOf(Type),
            .fields = expectedFields(Type),
        };
        index += 1;
    }
    return result;
}

fn expectedFields(comptime Type: type) []const ExpectedField {
    const fields = comptime fields: {
        const info = switch (@typeInfo(Type)) {
            inline .@"struct", .@"union" => |info| info,
            else => unreachable,
        };
        var result: [info.field_names.len]ExpectedField = undefined;
        for (info.field_names, &result) |name, *field| field.* = .{
            .name = name,
            .offset = if (@typeInfo(Type) == .@"union") 0 else @offsetOf(Type, name),
        };
        break :fields result;
    };
    return &fields;
}

fn isWireAggregateDeclaration(comptime name: []const u8) bool {
    if (!isWireTypeName(name)) return false;
    const declaration = @field(wire, name);
    if (@TypeOf(declaration) != type) return false;
    return switch (@typeInfo(declaration)) {
        .@"struct", .@"union" => true,
        else => false,
    };
}

fn isWireTypeName(comptime name: []const u8) bool {
    const generated_name = std.mem.startsWith(u8, name, "BunBind_") or
        std.mem.startsWith(u8, name, "BunBindEngine_") or
        std.mem.startsWith(u8, name, "BunBindNative_");
    if (generated_name and !std.mem.endsWith(u8, name, "_OFFSET")) return true;
    if (std.mem.startsWith(u8, name, "bun_bindgen_class_") and
        std.mem.endsWith(u8, name, "_Fields")) return true;
    return std.mem.eql(u8, name, "BindCallContext") or
        std.mem.eql(u8, name, "BindJSValueSlice") or
        std.mem.eql(u8, name, "BindEncodedJSValueSlice") or
        std.mem.eql(u8, name, "BindClassRefView") or
        std.mem.eql(u8, name, "BindClassRef") or
        std.mem.eql(u8, name, "BindByteSlice") or
        std.mem.eql(u8, name, "BindConstByteSlice") or
        std.mem.eql(u8, name, "BindConstNativeU8Slice") or
        std.mem.eql(u8, name, "BindNativeU8Slice") or
        std.mem.eql(u8, name, "BindConstNativeU16Slice") or
        std.mem.eql(u8, name, "BindNativeU16Slice") or
        std.mem.eql(u8, name, "BindConstNativeU32Slice") or
        std.mem.eql(u8, name, "BindNativeU32Slice") or
        std.mem.eql(u8, name, "BindConstNativeU64Slice") or
        std.mem.eql(u8, name, "BindNativeU64Slice") or
        std.mem.eql(u8, name, "BindCloneReader") or
        std.mem.eql(u8, name, "BindStringView");
}

const PackedName = struct {
    len: usize,
    words: []const u64,

    fn byteAt(name: PackedName, index: usize) u8 {
        return @truncate(name.words[index / 8] >> @intCast((index % 8) * 8));
    }

    fn compare(a: PackedName, b: []const u8) std.math.Order {
        const shared_len = @min(a.len, b.len);
        for (0..shared_len) |index| {
            const a_byte = a.byteAt(index);
            const b_byte = b[index];
            if (a_byte < b_byte) return .lt;
            if (a_byte > b_byte) return .gt;
        }
        return std.math.order(a.len, b.len);
    }

    fn write(name: PackedName, out: *std.Io.Writer) !void {
        for (0..name.len) |index| try out.writeByte(name.byteAt(index));
    }
};

const Cursor = struct {
    values: []const u64,

    fn read(cursor: *Cursor) error{MalformedWireLayoutTable}!u64 {
        if (cursor.values.len == 0) return error.MalformedWireLayoutTable;
        defer cursor.values = cursor.values[1..];
        return cursor.values[0];
    }

    fn readName(cursor: *Cursor) error{MalformedWireLayoutTable}!PackedName {
        const len = std.math.cast(usize, try cursor.read()) orelse return error.MalformedWireLayoutTable;
        if (len == 0) return error.MalformedWireLayoutTable;
        const word_count = len / 8 + @intFromBool(len % 8 != 0);
        if (word_count > cursor.values.len) return error.MalformedWireLayoutTable;
        const words = cursor.values[0..word_count];
        cursor.values = cursor.values[word_count..];
        if (len % 8 != 0 and words[words.len - 1] >> @intCast((len % 8) * 8) != 0) {
            return error.MalformedWireLayoutTable;
        }
        return .{ .len = len, .words = words };
    }
};

fn tableCursor(values: []const u64) error{MalformedWireLayoutTable}!Cursor {
    if (values.len < 2 or values[0] != layout_magic or values[1] != layout_version) {
        return error.MalformedWireLayoutTable;
    }
    return .{ .values = values[2..] };
}

fn compareEntry(
    out: *std.Io.Writer,
    mismatches: *usize,
    cursor: *Cursor,
    expected: ?ExpectedType,
) !void {
    const size = try cursor.read();
    const alignment = try cursor.read();
    const clang_field_count = std.math.cast(usize, try cursor.read()) orelse return error.MalformedWireLayoutTable;
    if (clang_field_count > cursor.values.len) return error.MalformedWireLayoutTable;
    if (expected) |t| {
        try compare(out, mismatches, t.name, "sizeof", size, t.size);
        try compare(out, mismatches, t.name, "alignof", alignment, t.alignment);
        if (clang_field_count != t.fields.len) {
            mismatches.* += 1;
            try out.print(
                "wire layout field count mismatch for {s}: clang emitted {d}, Zig translated {d}\n",
                .{ t.name, clang_field_count, t.fields.len },
            );
        }
    }
    for (0..clang_field_count) |field_index| {
        const clang_name = try cursor.readName();
        const clang_offset = try cursor.read();
        const t = expected orelse continue;
        if (field_index >= t.fields.len) {
            mismatches.* += 1;
            try out.print("unknown clang wire field in {s}: ", .{t.name});
            try clang_name.write(out);
            try out.writeByte('\n');
            continue;
        }
        const expected_field = t.fields[field_index];
        if (clang_name.compare(expected_field.name) != .eq) {
            mismatches.* += 1;
            try out.print(
                "wire layout field mismatch in {s}: clang emitted ",
                .{t.name},
            );
            try clang_name.write(out);
            try out.print(", Zig translated {s}\n", .{expected_field.name});
            continue;
        }
        try compare(
            out,
            mismatches,
            t.name,
            expected_field.name,
            clang_offset,
            expected_field.offset,
        );
    }
}

fn compare(
    out: *std.Io.Writer,
    mismatches: *usize,
    name: []const u8,
    what: []const u8,
    clang_value: u64,
    zig_value: u64,
) !void {
    if (clang_value == zig_value) return;
    mismatches.* += 1;
    try out.print(
        "wire layout mismatch: {s}({s}) is {d} under clang but {d} under Zig\n",
        .{ what, name, clang_value, zig_value },
    );
}
