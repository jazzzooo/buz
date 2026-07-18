pub const Authentication = union(enum) {
    Ok: void,
    ClearTextPassword: struct {},
    MD5Password: struct {
        salt: [4]u8,
    },
    KerberosV5: struct {},
    SCMCredential: struct {},
    GSS: struct {},
    GSSContinue: struct {
        data: Data,
    },
    SSPI: struct {},
    SASL: struct {},
    SASLContinue: struct {
        data: Data,
        r: []const u8,
        s: []const u8,
        i: []const u8,

        pub fn iterationCount(this: *const @This()) !u32 {
            return try std.fmt.parseInt(u32, this.i, 0);
        }
    },
    SASLFinal: struct {
        data: Data,
    },
    Unknown: void,

    pub fn deinit(this: *@This()) void {
        switch (this.*) {
            .MD5Password => {},
            .SASL => {},
            .SASLContinue => {
                this.SASLContinue.data.zdeinit();
            },
            .SASLFinal => {
                this.SASLFinal.data.zdeinit();
            },
            else => {},
        }
    }

    pub fn decode(this: *@This(), reader: PayloadReader) !void {
        const payload_length = reader.peek().len;

        switch (try reader.int4()) {
            0 => {
                if (payload_length != 4) return error.InvalidMessageLength;
                this.* = .{ .Ok = {} };
            },
            2 => {
                if (payload_length != 4) return error.InvalidMessageLength;
                this.* = .{
                    .KerberosV5 = .{},
                };
            },
            3 => {
                if (payload_length != 4) return error.InvalidMessageLength;
                this.* = .{
                    .ClearTextPassword = .{},
                };
            },
            5 => {
                if (payload_length != 8) return error.InvalidMessageLength;
                var salt_data = try reader.bytes(4);
                defer salt_data.deinit();
                this.* = .{
                    .MD5Password = .{
                        .salt = salt_data.slice()[0..4].*,
                    },
                };
            },
            7 => {
                if (payload_length != 4) return error.InvalidMessageLength;
                this.* = .{
                    .GSS = .{},
                };
            },

            8 => {
                if (payload_length < 5) return error.InvalidMessageLength;
                const bytes = try reader.read(payload_length - 4);
                this.* = .{
                    .GSSContinue = .{
                        .data = bytes,
                    },
                };
            },
            9 => {
                if (payload_length != 4) return error.InvalidMessageLength;
                this.* = .{
                    .SSPI = .{},
                };
            },

            10 => {
                if (payload_length < 5) return error.InvalidMessageLength;
                try reader.skip(payload_length - 4);
                this.* = .{
                    .SASL = .{},
                };
            },

            11 => {
                if (payload_length < 5) return error.InvalidMessageLength;
                var bytes = try reader.bytes(payload_length - 4);
                errdefer {
                    bytes.deinit();
                }

                var iter = bun.strings.split(bytes.slice(), ",");
                var r: ?[]const u8 = null;
                var i: ?[]const u8 = null;
                var s: ?[]const u8 = null;

                while (iter.next()) |item| {
                    if (item.len > 2) {
                        const key = item[0];
                        const after_equals = item[2..];
                        if (key == 'r') {
                            r = after_equals;
                        } else if (key == 's') {
                            s = after_equals;
                        } else if (key == 'i') {
                            i = after_equals;
                        }
                    }
                }

                if (r == null) {
                    debug("Missing r", .{});
                }

                if (s == null) {
                    debug("Missing s", .{});
                }

                if (i == null) {
                    debug("Missing i", .{});
                }

                this.* = .{
                    .SASLContinue = .{
                        .data = bytes,
                        .r = r orelse return error.InvalidMessage,
                        .s = s orelse return error.InvalidMessage,
                        .i = i orelse return error.InvalidMessage,
                    },
                };
            },

            12 => {
                if (payload_length < 5) return error.InvalidMessageLength;
                const remaining = payload_length - 4;

                const bytes = try reader.read(remaining);
                this.* = .{
                    .SASLFinal = .{
                        .data = bytes,
                    },
                };
            },

            else => {
                try reader.skip(reader.peek().len);
                this.* = .{ .Unknown = {} };
            },
        }
    }
};

const debug = bun.Output.scoped(.Postgres, .hidden);

const bun = @import("bun");
const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const PayloadReader = @import("./NewReader.zig").PayloadReader;
