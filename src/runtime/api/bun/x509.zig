pub const LegacyCertificate = bindgen.Return(LegacyCertificateSchema);
const Data = bindgen.Return(ToLegacyObjectSchema);
const CallbackValue = @FieldType(bindgen.Args(bindgen.CallbackSchema("FetchCheckServerIdentityCallback")), "certificate");
const StringOperand = @typeInfo(@FieldType(CallbackValue, "subjectaltname")).optional.child;
const StringSequence = @typeInfo(@FieldType(LegacyCertificate, "ext_key_usage")).optional.child;
const NameEntry = std.meta.Elem(@typeInfo(@FieldType(CallbackValue, "subject")).optional.child);
const InfoEntry = std.meta.Elem(@typeInfo(@FieldType(CallbackValue, "infoAccess")).optional.child);

pub const CallbackCertificate = struct {
    value: CallbackValue,
    owner: LegacyCertificate,
    strings: std.ArrayList(bindgen.DOMString) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn fromOwned(owner: LegacyCertificate) bun.OOM!CallbackCertificate {
        var result: CallbackCertificate = .{
            .value = undefined,
            .owner = owner,
            .arena = .init(bun.default_allocator),
        };
        errdefer result.deinit();
        result.value = .{
            .subject = if (result.owner.subject) |*record| try result.takeRecord(NameEntry, record) else null,
            .issuer = if (result.owner.issuer) |*record| try result.takeRecord(NameEntry, record) else null,
            .infoAccess = if (result.owner.infoAccess) |*record| try result.takeRecord(InfoEntry, record) else null,
            .ext_key_usage = if (result.owner.ext_key_usage) |*sequence| try result.takeStrings(sequence) else null,
            .subjectaltname = null,
            .bits = owner.bits,
            .pubkey = if (owner.pubkey) |*bytes| bytes.operand() else null,
            .valid_from = null,
            .valid_to = null,
            .fingerprint = null,
            .fingerprint256 = null,
            .fingerprint512 = null,
            .serialNumber = null,
            .raw = owner.raw.operand(),
            .ca = owner.ca,
        };
        inline for (.{ "subjectaltname", "modulus", "exponent", "asn1Curve", "nistCurve", "valid_from", "valid_to", "fingerprint", "fingerprint256", "fingerprint512", "serialNumber" }) |field| {
            @field(result.value, field) = if (@field(result.owner, field)) |*text| text.operand() else null;
        }
        return result;
    }

    fn keepString(self: *CallbackCertificate, string: *bindgen.DOMString) bun.OOM!StringOperand {
        try self.strings.ensureUnusedCapacity(self.arena.allocator(), 1);
        const owned = string.take();
        self.strings.appendAssumeCapacity(owned);
        return owned.operand();
    }

    fn takeStrings(self: *CallbackCertificate, sequence: *StringSequence) bun.OOM![]const StringOperand {
        const values = try self.arena.allocator().alloc(StringOperand, sequence.len());
        var iterator = sequence.iterator();
        for (values) |*value| {
            var item = iterator.next().?.value;
            defer item.deinit();
            value.* = try self.keepString(&item);
        }
        return values;
    }

    fn takeRecord(self: *CallbackCertificate, comptime Entry: type, record: anytype) bun.OOM![]const Entry {
        const entries = try self.arena.allocator().alloc(Entry, record.len());
        var iterator = record.iterator();
        for (entries) |*entry| {
            var item = (try iterator.next()).?;
            defer item.deinit();
            entry.* = .{
                .key = try self.keepString(&item.key),
                .value = if (Entry == NameEntry) switch (item.value) {
                    .value => |*text| .{ .value = try self.keepString(text) },
                    .values => |*values| .{ .values = try self.takeStrings(values) },
                } else if (Entry == InfoEntry)
                    try self.takeStrings(&item.value)
                else
                    @compileError("unsupported certificate record entry"),
            };
        }
        return entries;
    }

    pub fn deinit(self: *CallbackCertificate) void {
        for (self.strings.items) |*string| string.deinit();
        deinitLegacyCertificate(&self.owner);
        self.arena.deinit();
    }
};

pub fn deinitLegacyCertificate(data: *LegacyCertificate) void {
    bindgen.deinitResult(LegacyCertificateSchema.ReturnType, data);
}

fn bytesToOwned(sequence: anytype) bun.OOM!bindgen.OwnedBytes {
    var result = try bindgen.OwnedBytes.initUninitialized(sequence.len());
    errdefer result.deinit();
    var iterator = sequence.iterator();
    var index: usize = 0;
    while (iterator.next()) |item| : (index += 1) result.mutableSlice()[index] = item.value;
    sequence.deinit();
    return result;
}

pub fn materializeLegacyCertificate(data: *Data) bun.OOM!LegacyCertificate {
    defer bindgen.deinitReturn(ToLegacyObjectSchema, data);
    var raw = try bytesToOwned(&data.raw);
    errdefer raw.deinit();
    var pubkey: ?bindgen.OwnedBytes = if (data.pubkey) |*bytes| try bytesToOwned(bytes) else null;
    var result: LegacyCertificate = undefined;
    inline for (@typeInfo(LegacyCertificate).@"struct".field_names) |field| {
        @field(result, field) = if (comptime std.mem.eql(u8, field, "raw"))
            raw.take()
        else if (comptime std.mem.eql(u8, field, "pubkey"))
            if (pubkey) |*bytes| bytes.take() else null
        else switch (@typeInfo(@FieldType(LegacyCertificate, field))) {
            .optional => bun.take(&@field(data, field)),
            .bool => @field(data, field),
            else => @compileError("certificate field requires an explicit ownership conversion: " ++ field),
        };
    }
    return result;
}

pub fn legacyCertificateFromContext(context: anytype, cert: *BoringSSL.X509) bun.JSError!LegacyCertificate {
    var data = try context.engineIn("X509", "x509ToLegacyObject").call(.{ .certificate = @ptrCast(cert) });
    return materializeLegacyCertificate(&data);
}

const std = @import("std");
const bun = @import("bun");
const bindgen = bun.bindgen;
const BoringSSL = bun.BoringSSL.c;
const X509Bindings = bindgen.Module("X509");
const ToLegacyObjectSchema = X509Bindings.engineShim("x509ToLegacyObject");
const LegacyCertificateSchema = X509Bindings.function("certificateToLegacyObject");
