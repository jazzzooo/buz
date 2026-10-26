//! An IP socket address meant to be used by both native and JS code.
//!
//! JS getters are named `getFoo`, while native getters are named `foo`.
//!
//! TODO: add a inspect method (under `Symbol.for("nodejs.util.inspect.custom")`).
//! Requires updating bindgen.

const SocketAddress = @This();

pub const new = bun.TrivialNew(SocketAddress);
pub const getConstructor = SocketAddressClass.constructor;
pub const fromJS = SocketAddressClass.fromJS;

bindgen_state: bindgen.ClassState = .{},

// NOTE: not std.net.Address b/c .un is huge and we don't use it.
// NOTE: not C.sockaddr_storage b/c it's _huge_. we need >= 28 bytes for sockaddr_in6,
// but sockaddr_storage is 128 bytes.
/// @internal
value: SocketAddressValue,
/// Cached address in presentation format. Prevents repeated conversion between
/// strings and bytes.
///
/// @internal
_presentation: ?bindgen.DOMString = null,

pub const Options = struct {
    family: AF = AF.INET,
    /// When `null`, default is determined by address family.
    /// - `127.0.0.1` for IPv4
    /// - `::1` for IPv6
    address: ?bindgen.DOMString = null,
    port: u16 = 0,
    /// IPv6 flow label. JS getters for v4 addresses always return `0`.
    flowlabel: ?u32 = null,

    pub fn deinit(this: *Options) void {
        if (this.address) |*address| address.deinit();
        this.address = null;
    }
};

// =============================================================================
// ============================== STATIC METHODS ===============================
// =============================================================================

/// ### `SocketAddress.parse(input: string): SocketAddress | undefined`
/// Parse an address string (with an optional `:port`) into a `SocketAddress`.
/// Returns `undefined` if the input is invalid.
pub fn parse(
    context: bindgen.CallContext(SocketAddressParseSchema),
    args: bindgen.Args(SocketAddressParseSchema),
) bun.JSError!bindgen.Return(SocketAddressParseSchema) {
    var bound_input = args.input.toOwned();
    defer bound_input.deinit();
    var input = bound_input.takeBunString();
    defer input.deref();

    const prefix = "http://";
    const url_str = switch (input.is8Bit()) {
        inline else => |is_8_bit| with_prefix: {
            const enc: bun.String.WTFEncoding = if (is_8_bit) .latin1 else .utf16;
            const from_chars = if (is_8_bit) input.latin1() else input.utf16();
            const str, const to_chars = bun.String.createUninitialized(enc, from_chars.len + prefix.len);
            @memcpy(to_chars[0..prefix.len], bun.strings.literal(enc.Byte(), prefix));
            @memcpy(to_chars[prefix.len..], from_chars);
            break :with_prefix str;
        },
    };
    defer url_str.deref();

    var bound_url = try bindgen.ThreadSafeDOMString.fromBunString(url_str.dupeRef());
    defer bound_url.deinit();
    var url = (try context.engineIn("urls", "urlFromString").call(.{ .input = bound_url.operand() })) orelse return null;
    defer url.deinit();
    var bound_host = try context.engineIn("urls", "urlHost").call(.{ .url = &url });
    var host = bound_host.takeBunString();
    defer host.deref();
    const port_: u16 = context.engineIn("urls", "urlPort").call(.{ .url = &url }) orelse 0;
    bun.assert(host.tag != .Dead);
    bun.debugAssert(host.length() >= 2);

    // NOTE: parsed host cannot be used as presentation string. e.g.
    // - "[::1]" -> "::1"
    // - "0x.0x.0" -> "0.0.0.0"
    const paddr = host.latin1(); // presentation address
    const addr = if (paddr[0] == '[' and paddr[paddr.len - 1] == ']') v6: {
        const v6 = net.Ip6Address.parse(paddr[1 .. paddr.len - 1], port_) catch return null;
        break :v6 SocketAddress.initIp6(v6.bytes, v6.port, v6.flow, v6.interface.index);
    } else v4: {
        const v4 = net.Ip4Address.parse(paddr, port_) catch return null;
        break :v4 SocketAddress.initIp4(v4.bytes, v4.port);
    };

    const socket_address = SocketAddress.new(addr);
    return try SocketAddressClass.adoptResult(socket_address, context);
}

/// ### `SocketAddress.isSocketAddress(value: unknown): value is SocketAddress`
/// Returns `true` if `value` is a `SocketAddress`. Subclasses and similarly-shaped
/// objects are not considered `SocketAddress`s.
pub fn isSocketAddress(
    _: bindgen.CallContext(SocketAddressIsSocketAddressSchema),
    args: bindgen.Args(SocketAddressIsSocketAddressSchema),
) bun.JSError!bool {
    return args.value != null;
}

// =============================================================================
// =============================== CONSTRUCTORS ================================
// =============================================================================

/// `new SocketAddress([options])`
///
/// ## References
/// - [Node docs](https://nodejs.org/api/net.html#new-netsocketaddressoptions)
pub fn construct(
    context: bindgen.CallContext(SocketAddressConstructorSchema),
    args: bindgen.Args(SocketAddressConstructorSchema),
) bindgen.CallError(SocketAddressConstructorSchema)!*SocketAddress {
    const generated = args.options orelse return SocketAddress.new(.{
        .value = .{ .raw = sockaddr.@"127.0.0.1" },
    });

    var options: Options = .{
        .family = switch (generated.family) {
            .ipv4 => AF.INET,
            .ipv6 => AF.INET6,
        },
        .address = if (generated.address) |address| address.toOwned() else null,
        .port = generated.port,
        .flowlabel = generated.flowlabel,
    };
    defer options.deinit();

    // fast path for { family: 'ipv6' }
    if (options.family == AF.INET6 and options.address == null and options.flowlabel == null and options.port == 0) {
        return SocketAddress.new(.{
            .value = .{ .raw = sockaddr.@"::" },
        });
    }

    const address = SocketAddress.initOptions(&options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAddress => return context.fail(.invalid_address, {}),
    };
    return SocketAddress.new(address);
}

pub fn initFromAddressFamily(address: bindgen.DOMStringView, address_family: AF) ParseError!SocketAddress {
    var options: Options = .{
        .family = address_family,
        .address = address.toOwned(),
    };
    defer options.deinit();
    return .initOptions(&options);
}

pub const ParseError = error{ InvalidAddress, OutOfMemory };

pub fn initOptions(options: *Options) ParseError!SocketAddress {
    var presentation_value: ?bindgen.DOMString = null;

    // We need a zero-terminated cstring for `ares_inet_pton`, which forces us to
    // copy the string.
    var stackfb_buffer: [64]u8 = undefined;
    var stackfb: std.heap.BufferFirstAllocator = .init(&stackfb_buffer, bun.default_allocator);
    const alloc = stackfb.allocator();

    // NOTE: `zig translate-c` creates semantically invalid code for `C.ntohs`.
    // Switch back to `htons(options.port)` when this issue gets resolved:
    // https://github.com/ziglang/zig/issues/22804
    const addr: sockaddr = switch (options.family) {
        AF.INET => v4: {
            var sin: inet.sockaddr_in = .{
                .family = options.family.int(),
                .port = std.mem.nativeToBig(u16, options.port),
                .addr = undefined,
            };
            if (options.address) |*address_str| {
                const slice = try address_str.toOwnedSliceZ(alloc);
                defer alloc.free(slice);
                try pton(inet.AF_INET, slice, &sin.addr);
                presentation_value = options.address;
                options.address = null;
            } else {
                sin.addr = sockaddr.@"127.0.0.1".sin.addr;
            }
            break :v4 .{ .sin = sin };
        },
        AF.INET6 => v6: {
            var sin6: inet.sockaddr_in6 = .{
                .family = options.family.int(),
                .port = std.mem.nativeToBig(u16, options.port),
                .flowinfo = options.flowlabel orelse 0,
                .addr = undefined,
                .scope_id = 0,
            };
            if (options.address) |*address_str| {
                const slice = try address_str.toOwnedSliceZ(alloc);
                defer alloc.free(slice);
                try pton(inet.AF_INET6, slice, &sin6.addr);
                presentation_value = options.address;
                options.address = null;
            } else {
                sin6.addr = inet.IN6ADDR_ANY_INIT;
            }
            break :v6 .{ .sin6 = sin6 };
        },
    };

    return .{
        .value = .{ .raw = addr },
        ._presentation = presentation_value,
    };
}

pub const AddressError = SocketAddressValue.AddressError;

/// Create a new IP socket address. `addr` is assumed to be a valid ipv4 or ipv6
/// address. Port is in host byte order.
///
/// ## Errors
/// - If `addr` is not 4 or 16 bytes long.
pub fn init(addr: []const u8, port_: u16) AddressError!SocketAddress {
    return .{ .value = try .init(addr, port_) };
}

/// Create an IPv4 socket address. `addr` is assumed to be valid. Port is in host byte order.
pub fn initIPv4(addr: [4]u8, port_: u16) SocketAddress {
    return .{ .value = .initIp4(addr, port_) };
}

/// Create an IPv6 socket address. `addr` is assumed to be valid. Port is in
/// host byte order.
///
/// Use `0` for `flowinfo` and `scope_id` if you don't know or care about their
/// values.
pub fn initIPv6(addr: [16]u8, port_: u16, flowinfo: u32, scope_id: u32) SocketAddress {
    return .{ .value = .initIp6(addr, port_, flowinfo, scope_id) };
}

// =============================================================================
// ================================ DESTRUCTORS ================================
// =============================================================================

fn deinit(this: *SocketAddress) void {
    if (this._presentation) |*value| value.deinit();
    bun.destroy(this);
}

pub fn destroy(this: *SocketAddress) void {
    this.deinit();
}

pub fn initIp4(bytes: [4]u8, port_: u16) SocketAddress {
    return .{ .value = .initIp4(bytes, port_) };
}

pub fn initIp6(bytes: [16]u8, port_: u16, flowinfo: u32, scope_id: u32) SocketAddress {
    return .{ .value = .initIp6(bytes, port_, flowinfo, scope_id) };
}

pub fn fromPosix(address_: *const std.posix.sockaddr) ?SocketAddress {
    return .{ .value = SocketAddressValue.fromPosix(address_) orelse return null };
}

pub fn formatIp(this: *const SocketAddress, buf: []u8) []const u8 {
    return this.value.formatIp(buf);
}

pub fn address4(this: *const SocketAddress) u32 {
    return this.value.address4();
}

pub fn address6(this: *const SocketAddress) [16]u8 {
    return this.value.address6();
}

pub fn scopeId(this: *const SocketAddress) u32 {
    return this.value.scopeId();
}

// =============================================================================

/// Turn this address into an owned DTO. `this` is consumed and undefined after this call.
pub fn intoDTO(this: *SocketAddress, comptime DTO: type) bun.OOM!DTO {
    _ = try this.presentation();
    const address = this._presentation.?;
    this._presentation = null;
    return .{
        .address = address,
        .family = if (this.family() == AF.INET6) .ipv6 else .ipv4,
        .port = this.port(),
    };
}

pub fn createDTO(comptime DTO: type, addr_: []const u8, port_: u16, is_ipv6: bool) bun.OOM!DTO {
    if (comptime bun.Environment.isDebug) {
        bun.assertWithLocation(addr_.len > 0, @src());
    }

    return .{
        .address = try bindgen.DOMString.fromUTF8(addr_),
        .family = if (is_ipv6) .ipv6 else .ipv4,
        .port = port_,
    };
}

// =============================================================================

pub fn getAddress(
    this: *SocketAddress,
    _: bindgen.CallContext(SocketAddressAddressSchema),
    _: bindgen.Args(SocketAddressAddressSchema),
) bun.JSError!bindgen.DOMString {
    return (try this.presentation()).clone();
}

/// Get the address in presentation format. Does not include the port.
///
fn presentation(this: *SocketAddress) bun.OOM!*const bindgen.DOMString {
    if (this._presentation) |*value| return value;
    var buf: [inet.INET6_ADDRSTRLEN]u8 = undefined;
    const formatted = this.value.raw.fmt(&buf);
    this._presentation = try bindgen.DOMString.fromLatin1(formatted);
    return &this._presentation.?;
}

/// `sockaddr.family`
///
/// Returns a string representation of this address' family. Use `getAddrFamily`
/// for the numeric value.
///
/// NOTE: node's `net.SocketAddress` wants `"ipv4"` and `"ipv6"` while Bun's APIs
/// use `"IPv4"` and `"IPv6"`. This is annoying.
pub fn getFamily(
    this: *SocketAddress,
    _: bindgen.CallContext(SocketAddressFamilySchema),
    _: bindgen.Args(SocketAddressFamilySchema),
) bun.JSError!bindgen.DOMString {
    return bindgen.DOMString.fromUTF8(switch (this.family()) {
        AF.INET => "ipv4",
        AF.INET6 => "ipv6",
    });
}

/// `sockaddr.addrfamily`
pub fn getAddrFamily(
    this: *SocketAddress,
    _: bindgen.CallContext(SocketAddressAddrfamilySchema),
    _: bindgen.Args(SocketAddressAddrfamilySchema),
) bun.JSError!i32 {
    return @intCast(this.family().int());
}

/// NOTE: zig std uses posix values only, while this returns whatever the
/// system uses. Do not compare to `std.posix.AF`.
pub fn family(this: *const SocketAddress) AF {
    return this.value.family();
}

pub fn getPort(
    this: *SocketAddress,
    _: bindgen.CallContext(SocketAddressPortSchema),
    _: bindgen.Args(SocketAddressPortSchema),
) bun.JSError!u16 {
    return this.port();
}

/// Get the port number in host byte order.
pub fn port(this: *const SocketAddress) u16 {
    return this.value.port();
}

pub fn getFlowLabel(
    this: *SocketAddress,
    _: bindgen.CallContext(SocketAddressFlowlabelSchema),
    _: bindgen.Args(SocketAddressFlowlabelSchema),
) bun.JSError!u32 {
    return this.flowLabel() orelse 0;
}

/// Returns `null` for non-IPv6 addresses.
///
/// ## References
/// - [RFC 6437](https://tools.ietf.org/html/rfc6437)
pub fn flowLabel(this: *const SocketAddress) ?u32 {
    return this.value.flowLabel();
}

pub fn memoryUsage(this: *const SocketAddress, _: bun.bindgen.MemoryUsageContext(.any)) usize {
    return @sizeOf(SocketAddress) + if (this._presentation) |*value| value.length() * @sizeOf(u16) else 0;
}

pub fn toJSON(
    this: *SocketAddress,
    _: bindgen.CallContext(SocketAddressToJSONSchema),
    _: bindgen.Args(SocketAddressToJSONSchema),
) bun.JSError!bindgen.Return(SocketAddressToJSONSchema) {
    var address = (try this.presentation()).clone();
    errdefer address.deinit();
    var family_name = try bindgen.DOMString.fromUTF8(switch (this.family()) {
        .INET => "ipv4",
        .INET6 => "ipv6",
    });
    errdefer family_name.deinit();
    return .{
        .address = address,
        .family = family_name,
        .port = this.port(),
        .flowlabel = this.flowLabel() orelse 0,
    };
}

fn pton(comptime af: c_int, addr: [:0]const u8, dst: *anyopaque) ParseError!void {
    return switch (ares.ares_inet_pton(af, addr.ptr, dst)) {
        0, -1 => error.InvalidAddress,
        1 => {},
        else => unreachable,
    };
}

pub const AF = SocketAddressValue.AF;
pub const sockaddr = SocketAddressValue.sockaddr;
pub const inet = SocketAddressValue.inet;
const bun = @import("bun");
const ares = bun.c_ares;
const bindgen = bun.bindgen;
const SocketAddressValue = @import("./SocketAddressValue.zig");

const BindingModule = bindgen.Module("SocketAddress");
const SocketAddressSchema = BindingModule.class("SocketAddress");
const SocketAddressConstructorSchema = SocketAddressSchema.constructor();
const SocketAddressAddressSchema = SocketAddressSchema.member("address");
const SocketAddressAddrfamilySchema = SocketAddressSchema.member("addrfamily");
const SocketAddressFamilySchema = SocketAddressSchema.member("family");
const SocketAddressFlowlabelSchema = SocketAddressSchema.member("flowlabel");
const SocketAddressPortSchema = SocketAddressSchema.member("port");
const SocketAddressToJSONSchema = SocketAddressSchema.member("toJSON");
const SocketAddressIsSocketAddressSchema = SocketAddressSchema.member("isSocketAddress");
const SocketAddressParseSchema = SocketAddressSchema.member("parse");
const SocketAddressClass = bindgen.Class(SocketAddressSchema, SocketAddress);

const std = @import("std");
const net = std.Io.net;

comptime {
    _ = SocketAddressClass;
}
