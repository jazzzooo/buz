/// Transport-agnostic request handle. Static/file routes (and RangeRequest)
/// take this so the same handler body serves HTTP/1.1 and HTTP/3 without
/// `anytype` — `inline else` keeps dispatch monomorphic.
pub const AnyRequest = union(enum) {
    h1: *Request,
    h3: *uws.H3.Request,

    pub fn header(this: AnyRequest, name: []const u8) ?[]const u8 {
        return switch (this) {
            inline else => |r| r.header(name),
        };
    }
    pub fn method(this: AnyRequest) []const u8 {
        return switch (this) {
            inline else => |r| r.method(),
        };
    }
    pub fn url(this: AnyRequest) []const u8 {
        return switch (this) {
            inline else => |r| r.url(),
        };
    }
    pub fn setYield(this: AnyRequest, y: bool) void {
        switch (this) {
            inline else => |r| r.setYield(y),
        }
    }
};

/// uWS::Request C++ -> Zig bindings.
pub const Request = opaque {
    pub fn setParameters(req: *Request, parameters: *const []const []const u8) void {
        c.uws_req_set_parameter_source(req, @ptrCast(@constCast(parameters)), parameterAt);
    }

    pub fn clearParameters(req: *Request) void {
        c.uws_req_set_parameter_source(req, null, null);
    }
    pub fn isAncient(req: *Request) bool {
        return c.uws_req_is_ancient(req);
    }
    pub fn getYield(req: *Request) bool {
        return c.uws_req_get_yield(req);
    }
    pub fn setYield(req: *Request, yield: bool) void {
        c.uws_req_set_yield(req, yield);
    }
    pub fn url(req: *Request) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..c.uws_req_get_url(req, &ptr)];
    }
    pub fn method(req: *Request) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..c.uws_req_get_method(req, &ptr)];
    }

    pub fn rawMethod(req: *Request) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..c.uws_req_get_raw_method(req, &ptr)];
    }
    pub fn header(req: *Request, name: []const u8) ?[]const u8 {
        bun.assert(std.ascii.isLower(name[0]));

        var ptr: [*]const u8 = undefined;
        const len = c.uws_req_get_header(req, name.ptr, name.len, &ptr);
        if (len == 0) return null;
        return ptr[0..len];
    }
    pub fn query(req: *Request, name: []const u8) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..c.uws_req_get_query(req, name.ptr, name.len, &ptr)];
    }
    pub fn parameter(req: *Request, index: u16) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..c.uws_req_get_parameter(req, @as(c_ushort, @intCast(index)), &ptr)];
    }
};

const c = struct {
    extern fn uws_req_get_raw_method(*Request, *[*]const u8) usize;
    extern fn uws_req_set_parameter_source(*Request, ?*anyopaque, ?*const fn (*anyopaque, c_uint, *[*]const u8) callconv(.c) usize) void;
    pub extern fn uws_req_is_ancient(res: *Request) bool;
    pub extern fn uws_req_get_yield(res: *Request) bool;
    pub extern fn uws_req_set_yield(res: *Request, yield: bool) void;
    pub extern fn uws_req_get_url(res: *Request, dest: *[*]const u8) usize;
    pub extern fn uws_req_get_method(res: *Request, dest: *[*]const u8) usize;
    pub extern fn uws_req_get_header(res: *Request, lower_case_header: [*]const u8, lower_case_header_length: usize, dest: *[*]const u8) usize;
    pub extern fn uws_req_get_query(res: *Request, key: [*c]const u8, key_length: usize, dest: *[*]const u8) usize;
    pub extern fn uws_req_get_parameter(res: *Request, index: c_ushort, dest: *[*]const u8) usize;
};

const std = @import("std");

pub fn parameterAt(context: *anyopaque, index: c_uint, output: *[*]const u8) callconv(.c) usize {
    const parameters: *const []const []const u8 = @ptrCast(@alignCast(context));
    const value: []const u8 = if (index < parameters.len) parameters.*[index] else "";
    output.* = value.ptr;
    return value.len;
}

const bun = @import("bun");
const uws = bun.uws;
