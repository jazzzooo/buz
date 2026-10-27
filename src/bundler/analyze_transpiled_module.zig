pub const RecordKind = enum(u8) {
    /// var_name
    declared_variable,
    /// let_name
    lexical_variable,
    /// module_name, import_name, local_name
    import_info_single,
    /// module_name, import_name, local_name
    import_info_single_type_script,
    /// module_name, import_name = '*', local_name
    import_info_namespace,
    /// export_name, import_name, module_name
    export_info_indirect,
    /// export_name, local_name, padding (for local => indirect conversion)
    export_info_local,
    /// export_name, module_name
    export_info_namespace,
    /// module_name
    export_info_star,
    _,

    pub fn len(record: RecordKind) !usize {
        return switch (record) {
            .declared_variable, .lexical_variable => 1,
            .import_info_single => 3,
            .import_info_single_type_script => 3,
            .import_info_namespace => 3,
            .export_info_indirect => 3,
            .export_info_local => 3,
            .export_info_namespace => 2,
            .export_info_star => 1,
            else => return error.InvalidRecordKind,
        };
    }

    fn moduleNameIndex(record: RecordKind) ?usize {
        return switch (record) {
            .import_info_single, .import_info_single_type_script, .import_info_namespace, .export_info_star => 0,
            .export_info_indirect => 2,
            .export_info_namespace => 1,
            .declared_variable, .lexical_variable, .export_info_local => null,
            else => unreachable,
        };
    }
};

pub const Flags = packed struct(u8) {
    contains_import_meta: bool = false,
    is_typescript: bool = false,
    has_tla: bool = false,
    _padding: u5 = 0,
};

pub const ModuleInfoDeserialized = struct {
    strings_buf: []const u8,
    strings_lens: []align(1) const u32,
    requested_modules_keys: []align(1) const StringID,
    requested_modules_values: []align(1) const ModuleInfo.FetchParameters,
    buffer: []align(1) const StringID,
    record_kinds: []align(1) const RecordKind,
    flags: Flags,
    owner: union(enum) {
        module_info,
        allocated_slice: struct {
            slice: []const u8,
            allocator: std.mem.Allocator,
        },
    },
    pub fn deinit(self: *ModuleInfoDeserialized) void {
        switch (self.owner) {
            .module_info => {
                const mi: *ModuleInfo = @fieldParentPtr("_deserialized", self);
                mi.destroy();
            },
            .allocated_slice => |as| {
                as.allocator.free(as.slice);
                as.allocator.destroy(self);
            },
        }
    }

    inline fn eat(rem: *[]const u8, len: usize) ![]const u8 {
        if (rem.*.len < len) return error.BadModuleInfo;
        const res = rem.*[0..len];
        rem.* = rem.*[len..];
        return res;
    }
    inline fn eatC(rem: *[]const u8, comptime len: usize) !*const [len]u8 {
        if (rem.*.len < len) return error.BadModuleInfo;
        const res = rem.*[0..len];
        rem.* = rem.*[len..];
        return res;
    }
    fn eatSlice(rem: *[]const u8, comptime T: type, count: u32) ![]align(1) const T {
        const byte_len = std.math.mul(usize, count, @sizeOf(T)) catch return error.BadModuleInfo;
        return std.mem.bytesAsSlice(T, try eat(rem, byte_len));
    }
    pub fn create(source: []const u8, gpa: std.mem.Allocator) !*ModuleInfoDeserialized {
        const duped = try gpa.dupe(u8, source);
        errdefer gpa.free(duped);
        var rem: []const u8 = duped;
        const res = try gpa.create(ModuleInfoDeserialized);
        errdefer gpa.destroy(res);

        const record_kinds_len = std.mem.readInt(u32, try eatC(&rem, 4), .little);
        const record_kinds = try eatSlice(&rem, RecordKind, record_kinds_len);
        _ = try eat(&rem, (4 - (record_kinds_len % 4)) % 4); // alignment padding

        const buffer_len = std.mem.readInt(u32, try eatC(&rem, 4), .little);
        const buffer = try eatSlice(&rem, StringID, buffer_len);

        const requested_modules_len = std.mem.readInt(u32, try eatC(&rem, 4), .little);
        const requested_modules_keys = try eatSlice(&rem, StringID, requested_modules_len);
        const requested_modules_values = try eatSlice(&rem, ModuleInfo.FetchParameters, requested_modules_len);

        const flags: Flags = @bitCast((try eatC(&rem, 1))[0]);
        _ = try eat(&rem, 3); // alignment padding

        const strings_len = std.mem.readInt(u32, try eatC(&rem, 4), .little);
        const strings_lens = try eatSlice(&rem, u32, strings_len);
        const strings_buf = rem;

        res.* = .{
            .strings_buf = strings_buf,
            .strings_lens = strings_lens,
            .requested_modules_keys = requested_modules_keys,
            .requested_modules_values = requested_modules_values,
            .buffer = buffer,
            .record_kinds = record_kinds,
            .flags = flags,
            .owner = .{ .allocated_slice = .{
                .slice = duped,
                .allocator = gpa,
            } },
        };
        try res.validate();
        return res;
    }

    pub fn validate(self: *const ModuleInfoDeserialized) error{BadModuleInfo}!void {
        if (self.flags._padding != 0 or self.strings_lens.len > @backingInt(ModuleInfo.FetchParameters.json)) return error.BadModuleInfo;
        var remaining_strings = self.strings_buf.len;
        for (self.strings_lens) |len| {
            if (len > remaining_strings) return error.BadModuleInfo;
            remaining_strings -= len;
        }
        if (remaining_strings != 0) return error.BadModuleInfo;

        if (self.requested_modules_keys.len != self.requested_modules_values.len) return error.BadModuleInfo;
        for (self.requested_modules_keys) |id| {
            if (@backingInt(id) >= self.strings_lens.len) return error.BadModuleInfo;
        }
        for (self.requested_modules_values) |kind| switch (kind) {
            .none, .javascript, .webassembly, .json => {},
            else => if (@backingInt(kind) >= self.strings_lens.len) return error.BadModuleInfo,
        };

        for (self.buffer) |id| {
            if (id != .star_default and id != .star_namespace and @backingInt(id) >= self.strings_lens.len) return error.BadModuleInfo;
        }
        var remaining_records = self.buffer;
        for (self.record_kinds) |kind| {
            const len = kind.len() catch return error.BadModuleInfo;
            if (len > remaining_records.len) return error.BadModuleInfo;
            const record = remaining_records[0..len];
            if (kind.moduleNameIndex()) |index| {
                if (@backingInt(record[index]) >= self.strings_lens.len) return error.BadModuleInfo;
            }
            if (kind == .import_info_namespace and record[1] != .star_namespace) return error.BadModuleInfo;
            if (kind == .export_info_local and record[2] != .star_default) return error.BadModuleInfo;
            remaining_records = remaining_records[len..];
        }
        if (remaining_records.len != 0) return error.BadModuleInfo;
    }

    /// Wrapper around `create` for use when loading from a cache (transpiler cache or standalone module graph).
    /// Corrupt data is a cache miss; allocation failure propagates to the caller.
    pub fn createFromCachedRecord(source: []const u8, gpa: std.mem.Allocator) bun.OOM!?*ModuleInfoDeserialized {
        return create(source, gpa) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadModuleInfo => null,
        };
    }

    pub fn serialize(self: *const ModuleInfoDeserialized, writer: anytype) !void {
        try self.validate();
        const record_kinds_len = std.math.cast(u32, self.record_kinds.len) orelse return error.BadModuleInfo;
        const buffer_len = std.math.cast(u32, self.buffer.len) orelse return error.BadModuleInfo;
        const requested_modules_len = std.math.cast(u32, self.requested_modules_keys.len) orelse return error.BadModuleInfo;
        const strings_len = std.math.cast(u32, self.strings_lens.len) orelse return error.BadModuleInfo;
        try writer.writeInt(u32, record_kinds_len, .little);
        try writer.writeAll(std.mem.sliceAsBytes(self.record_kinds));
        try writer.splatByteAll(0, (4 - (self.record_kinds.len % 4)) % 4); // alignment padding

        try writer.writeInt(u32, buffer_len, .little);
        try writer.writeAll(std.mem.sliceAsBytes(self.buffer));

        try writer.writeInt(u32, requested_modules_len, .little);
        try writer.writeAll(std.mem.sliceAsBytes(self.requested_modules_keys));
        try writer.writeAll(std.mem.sliceAsBytes(self.requested_modules_values));

        try writer.writeByte(@bitCast(self.flags));
        try writer.splatByteAll(0, 3); // alignment padding

        try writer.writeInt(u32, strings_len, .little);
        try writer.writeAll(std.mem.sliceAsBytes(self.strings_lens));
        try writer.writeAll(self.strings_buf);
    }
};

const StringMapKey = enum(u32) {
    _,
};
pub const StringContext = struct {
    strings_buf: []const u8,
    strings_lens: []const u32,

    pub fn hash(_: @This(), s: []const u8) u32 {
        return @as(u32, @truncate(std.hash.Wyhash.hash(0, s)));
    }
    pub fn eql(self: @This(), fetch_key: []const u8, item_key: StringMapKey, item_i: usize) bool {
        return bun.strings.eqlLong(fetch_key, self.strings_buf[@backingInt(item_key)..][0..self.strings_lens[item_i]], true);
    }
};

pub const ModuleInfo = struct {
    /// all strings in wtf-8. index in hashmap = StringID
    gpa: std.mem.Allocator,
    strings_map: std.array_hash_map.Custom(StringMapKey, void, void, true),
    strings_buf: std.ArrayList(u8),
    strings_lens: std.ArrayList(u32),
    requested_modules: std.array_hash_map.Auto(StringID, FetchParameters),
    buffer: std.ArrayList(StringID),
    record_kinds: std.ArrayList(RecordKind),
    flags: Flags,
    exported_names: std.array_hash_map.Auto(StringID, void),
    finalized: bool = false,

    /// only initialized after .finalize() is called
    _deserialized: ModuleInfoDeserialized,

    pub fn asDeserialized(self: *ModuleInfo) *ModuleInfoDeserialized {
        bun.assert(self.finalized);
        return &self._deserialized;
    }

    pub const FetchParameters = enum(u32) {
        none = std.math.maxInt(u32),
        javascript = std.math.maxInt(u32) - 1,
        webassembly = std.math.maxInt(u32) - 2,
        json = std.math.maxInt(u32) - 3,
        _, // host_defined: cast to StringID
        pub fn hostDefined(value: StringID) FetchParameters {
            return @fromBackingInt(@intCast(@backingInt(value)));
        }
    };

    pub const VarKind = enum { declared, lexical };
    pub fn addVar(self: *ModuleInfo, name: StringID, kind: VarKind) !void {
        switch (kind) {
            .declared => try self.addDeclaredVariable(name),
            .lexical => try self.addLexicalVariable(name),
        }
    }

    fn _addRecord(self: *ModuleInfo, kind: RecordKind, data: []const StringID) !void {
        bun.assert(!self.finalized);
        bun.assert(data.len == (kind.len() catch unreachable));
        try self.record_kinds.ensureUnusedCapacity(self.gpa, 1);
        try self.buffer.ensureUnusedCapacity(self.gpa, data.len);
        self.record_kinds.appendAssumeCapacity(kind);
        self.buffer.appendSliceAssumeCapacity(data);
    }
    pub fn addDeclaredVariable(self: *ModuleInfo, id: StringID) !void {
        try self._addRecord(.declared_variable, &.{id});
    }
    pub fn addLexicalVariable(self: *ModuleInfo, id: StringID) !void {
        try self._addRecord(.lexical_variable, &.{id});
    }
    pub fn addImportInfoSingle(self: *ModuleInfo, module_name: StringID, import_name: StringID, local_name: StringID, only_used_as_type: bool) !void {
        try self._addRecord(if (only_used_as_type) .import_info_single_type_script else .import_info_single, &.{ module_name, import_name, local_name });
    }
    pub fn addImportInfoNamespace(self: *ModuleInfo, module_name: StringID, local_name: StringID) !void {
        try self._addRecord(.import_info_namespace, &.{ module_name, .star_namespace, local_name });
    }
    pub fn addExportInfoIndirect(self: *ModuleInfo, export_name: StringID, import_name: StringID, module_name: StringID) !void {
        try self.addNamedExport(.export_info_indirect, export_name, &.{ export_name, import_name, module_name });
    }
    pub fn addExportInfoLocal(self: *ModuleInfo, export_name: StringID, local_name: StringID) !void {
        try self.addNamedExport(.export_info_local, export_name, &.{ export_name, local_name, .star_default });
    }
    pub fn addExportInfoNamespace(self: *ModuleInfo, export_name: StringID, module_name: StringID) !void {
        try self.addNamedExport(.export_info_namespace, export_name, &.{ export_name, module_name });
    }
    pub fn addExportInfoStar(self: *ModuleInfo, module_name: StringID) !void {
        try self._addRecord(.export_info_star, &.{module_name});
    }

    fn addNamedExport(self: *ModuleInfo, kind: RecordKind, name: StringID, data: []const StringID) !void {
        bun.assert(!self.finalized);
        if (self.exported_names.contains(name)) return;
        try self.exported_names.ensureUnusedCapacity(self.gpa, 1);
        try self._addRecord(kind, data);
        self.exported_names.putAssumeCapacityNoClobber(name, {});
    }

    pub fn create(gpa: std.mem.Allocator, is_typescript: bool) !*ModuleInfo {
        const res = try gpa.create(ModuleInfo);
        res.* = ModuleInfo.init(gpa, is_typescript);
        return res;
    }
    fn init(allocator: std.mem.Allocator, is_typescript: bool) ModuleInfo {
        return .{
            .gpa = allocator,
            .strings_map = .empty,
            .strings_buf = .empty,
            .strings_lens = .empty,
            .exported_names = .empty,
            .requested_modules = std.array_hash_map.Auto(StringID, FetchParameters).empty,
            .buffer = .empty,
            .record_kinds = .empty,
            .flags = .{ .contains_import_meta = false, .is_typescript = is_typescript },
            ._deserialized = undefined,
        };
    }
    fn deinit(self: *ModuleInfo) void {
        self.strings_map.deinit(self.gpa);
        self.strings_buf.deinit(self.gpa);
        self.strings_lens.deinit(self.gpa);
        self.exported_names.deinit(self.gpa);
        self.requested_modules.deinit(self.gpa);
        self.buffer.deinit(self.gpa);
        self.record_kinds.deinit(self.gpa);
    }
    pub fn destroy(self: *ModuleInfo) void {
        const alloc = self.gpa;
        self.deinit();
        alloc.destroy(self);
    }
    pub fn str(self: *ModuleInfo, value: []const u8) !StringID {
        bun.assert(!self.finalized);
        if (self.strings_map.getIndexAdapted(value, StringContext{
            .strings_buf = self.strings_buf.items,
            .strings_lens = self.strings_lens.items,
        })) |index| return @fromBackingInt(@intCast(index));

        const index = std.math.cast(u32, self.strings_map.count()) orelse return error.OutOfMemory;
        if (index >= @backingInt(FetchParameters.json)) return error.OutOfMemory;
        const offset = std.math.cast(u32, self.strings_buf.items.len) orelse return error.OutOfMemory;
        const len = std.math.cast(u32, value.len) orelse return error.OutOfMemory;
        _ = std.math.add(u32, offset, len) catch return error.OutOfMemory;

        var stable_value = value;
        var owned_value: ?[]u8 = null;
        defer if (owned_value) |bytes| self.gpa.free(bytes);
        const value_address = @intFromPtr(value.ptr);
        const buffer_address = @intFromPtr(self.strings_buf.items.ptr);
        if (value_address >= buffer_address) {
            const start = value_address - buffer_address;
            if (start <= self.strings_buf.items.len and value.len <= self.strings_buf.items.len - start) {
                owned_value = try self.gpa.dupe(u8, value);
                stable_value = owned_value.?;
            }
        }
        try self.strings_buf.ensureUnusedCapacity(self.gpa, value.len);
        try self.strings_lens.ensureUnusedCapacity(self.gpa, 1);
        const gpres = try self.strings_map.getOrPutAdapted(self.gpa, stable_value, StringContext{
            .strings_buf = self.strings_buf.items,
            .strings_lens = self.strings_lens.items,
        });
        bun.assert(!gpres.found_existing and gpres.index == index);
        gpres.key_ptr.* = @fromBackingInt(offset);
        gpres.value_ptr.* = {};
        self.strings_buf.appendSliceAssumeCapacity(stable_value);
        self.strings_lens.appendAssumeCapacity(len);
        return @fromBackingInt(index);
    }
    pub fn requestModule(self: *ModuleInfo, import_record_path: StringID, fetch_parameters: FetchParameters) !void {
        bun.assert(!self.finalized);
        // jsc only records the attributes of the first import with the given import_record_path. so only put if not exists.
        const gpres = try self.requested_modules.getOrPut(self.gpa, import_record_path);
        if (!gpres.found_existing) gpres.value_ptr.* = fetch_parameters;
    }

    pub fn replaceModuleSpecifier(self: *ModuleInfo, old_id: StringID, new_id: StringID) void {
        bun.assert(!self.finalized);
        if (old_id == new_id) return;
        var offset: usize = 0;
        for (self.record_kinds.items) |kind| {
            if (kind.moduleNameIndex()) |index| {
                const item = &self.buffer.items[offset + index];
                if (item.* == old_id) item.* = new_id;
            }
            offset += kind.len() catch unreachable;
        }
        if (self.requested_modules.getIndex(old_id)) |old_index| {
            if (self.requested_modules.getIndex(new_id)) |new_index| {
                if (new_index < old_index) {
                    self.requested_modules.orderedRemoveAt(old_index);
                    return;
                }
                self.requested_modules.orderedRemoveAt(new_index);
            }
            self.requested_modules.setKey(old_index, new_id);
        }
    }

    /// find any exports marked as 'local' that are actually 'indirect' and fix them
    pub fn finalize(self: *ModuleInfo) !void {
        bun.assert(!self.finalized);
        var local_name_to_module_name = std.array_hash_map.Auto(StringID, struct { module_name: StringID, import_name: StringID, record_kinds_idx: usize, is_namespace: bool }).empty;
        defer local_name_to_module_name.deinit(self.gpa);
        {
            var i: usize = 0;
            for (self.record_kinds.items, 0..) |k, idx| {
                if (k == .import_info_single or k == .import_info_single_type_script) {
                    try local_name_to_module_name.put(self.gpa, self.buffer.items[i + 2], .{ .module_name = self.buffer.items[i], .import_name = self.buffer.items[i + 1], .record_kinds_idx = idx, .is_namespace = false });
                } else if (k == .import_info_namespace) {
                    try local_name_to_module_name.put(self.gpa, self.buffer.items[i + 2], .{ .module_name = self.buffer.items[i], .import_name = .star_namespace, .record_kinds_idx = idx, .is_namespace = true });
                }
                i += k.len() catch unreachable;
            }
        }

        {
            var i: usize = 0;
            for (self.record_kinds.items) |*k| {
                if (k.* == .export_info_local) {
                    if (local_name_to_module_name.get(self.buffer.items[i + 1])) |ip| {
                        // `import * as z from M; export { z }` is a Namespace export per
                        // spec; encode it as indirect with import_name = .star_namespace
                        // so the record stays the same length and toJSModuleRecord
                        // dispatches to addNamespaceExport.
                        k.* = .export_info_indirect;
                        self.buffer.items[i + 1] = ip.import_name;
                        self.buffer.items[i + 2] = ip.module_name;
                        // In TypeScript, the re-exported import may target a type-only
                        // export that was elided. Convert the import to SingleTypeScript
                        // so JSC tolerates it being NotFound during linking.
                        if (!ip.is_namespace and self.flags.is_typescript) {
                            self.record_kinds.items[ip.record_kinds_idx] = .import_info_single_type_script;
                        }
                    }
                }
                i += k.len() catch unreachable;
            }
        }

        self._deserialized = .{
            .strings_buf = self.strings_buf.items,
            .strings_lens = self.strings_lens.items,
            .requested_modules_keys = self.requested_modules.keys(),
            .requested_modules_values = self.requested_modules.values(),
            .buffer = self.buffer.items,
            .record_kinds = self.record_kinds.items,
            .flags = self.flags,
            .owner = .module_info,
        };

        self.finalized = true;
    }
};
pub const StringID = enum(u32) {
    star_default = std.math.maxInt(u32),
    star_namespace = std.math.maxInt(u32) - 1,
    _,
};

test "module metadata updates preserve logical state on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var info = ModuleInfo.init(allocator, false);
            defer info.deinit();
            for (0..32) |index| {
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "export_{d}", .{index});
                const strings_count = info.strings_map.count();
                const strings_len = info.strings_buf.items.len;
                const id = info.str(name) catch |err| {
                    try std.testing.expectEqual(strings_count, info.strings_map.count());
                    try std.testing.expectEqual(strings_count, info.strings_lens.items.len);
                    try std.testing.expectEqual(strings_len, info.strings_buf.items.len);
                    return err;
                };
                const records_count = info.record_kinds.items.len;
                const buffer_len = info.buffer.items.len;
                const exports_count = info.exported_names.count();
                info.addExportInfoLocal(id, id) catch |err| {
                    try std.testing.expectEqual(records_count, info.record_kinds.items.len);
                    try std.testing.expectEqual(buffer_len, info.buffer.items.len);
                    try std.testing.expectEqual(exports_count, info.exported_names.count());
                    try std.testing.expect(!info.exported_names.contains(id));
                    return err;
                };
            }
            const substring_id = try info.str(info.strings_buf.items[1..8]);
            try std.testing.expectEqual(substring_id, try info.str("xport_0"));
            try info.finalize();
            try info.asDeserialized().validate();
        }
    }.run, .{});
}

test "module specifier replacement preserves identifiers and the first request" {
    var info = ModuleInfo.init(std.testing.allocator, false);
    defer info.deinit();
    var ids: [32]StringID = undefined;
    for (&ids, 0..) |*id, index| {
        var name_buffer: [32]u8 = undefined;
        id.* = try info.str(try std.fmt.bufPrint(&name_buffer, "module_{d}", .{index}));
        try info.requestModule(id.*, if (index == 0) .json else .javascript);
    }
    try info.addDeclaredVariable(ids[0]);
    try info.addImportInfoSingle(ids[0], ids[0], ids[0], false);
    try info.addExportInfoLocal(ids[0], ids[0]);
    try info.addExportInfoIndirect(ids[1], ids[0], ids[0]);
    try info.addExportInfoNamespace(ids[2], ids[0]);
    try info.addExportInfoStar(ids[0]);

    info.replaceModuleSpecifier(ids[0], ids[31]);
    try std.testing.expectEqual(@as(usize, 31), info.requested_modules.count());
    try std.testing.expectEqual(ids[31], info.requested_modules.keys()[0]);
    try std.testing.expectEqual(ModuleInfo.FetchParameters.json, info.requested_modules.get(ids[31]).?);
    try std.testing.expect(!info.requested_modules.contains(ids[0]));
    try std.testing.expectEqualSlices(StringID, &.{
        ids[0],
        ids[31],
        ids[0],
        ids[0],
        ids[0],
        ids[0],
        .star_default,
        ids[1],
        ids[0],
        ids[31],
        ids[2],
        ids[31],
        ids[31],
    }, info.buffer.items);

    info.replaceModuleSpecifier(ids[30], ids[31]);
    try std.testing.expectEqual(@as(usize, 30), info.requested_modules.count());
    try std.testing.expectEqual(ids[31], info.requested_modules.keys()[0]);
    try std.testing.expectEqual(ModuleInfo.FetchParameters.json, info.requested_modules.get(ids[31]).?);
    try std.testing.expect(!info.requested_modules.contains(ids[30]));

    const final_id = try info.str("final.js");
    info.replaceModuleSpecifier(ids[31], final_id);
    try std.testing.expectEqual(final_id, info.requested_modules.keys()[0]);
    try std.testing.expectEqual(ModuleInfo.FetchParameters.json, info.requested_modules.get(final_id).?);
    try std.testing.expect(!info.requested_modules.contains(ids[31]));
}

test "module metadata rejects corrupt lengths and records" {
    var source: [20]u8 = @splat(0);
    const empty = try ModuleInfoDeserialized.create(&source, std.testing.allocator);
    defer empty.deinit();
    std.mem.writeInt(u32, source[4..8], 0x40000000, .little);
    try std.testing.expectError(error.BadModuleInfo, ModuleInfoDeserialized.create(&source, std.testing.allocator));

    var info = ModuleInfo.init(std.testing.allocator, false);
    defer info.deinit();
    const name = try info.str("name");
    try info.addDeclaredVariable(name);
    try info.finalize();
    var record = info.asDeserialized().*;
    try record.validate();
    record.record_kinds = &.{@fromBackingInt(255)};
    try std.testing.expectError(error.BadModuleInfo, record.validate());
    record.record_kinds = &.{.import_info_single};
    try std.testing.expectError(error.BadModuleInfo, record.validate());
    record.record_kinds = &.{.declared_variable};
    record.buffer = &.{@fromBackingInt(1)};
    try std.testing.expectError(error.BadModuleInfo, record.validate());
    record.buffer = &.{name};
    record.strings_lens = &.{5};
    try std.testing.expectError(error.BadModuleInfo, record.validate());
}

const bun = @import("bun");
const std = @import("std");
