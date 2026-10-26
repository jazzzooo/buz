const BlockList = @This();

const RefCount = bun.ptr.RefCount(BlockList, "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;
pub const derefDeferred = RefCount.derefDeferred;
pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;
pub const getConstructor = BlockListClass.constructor;

ref_count: RefCount = .init(),
bindgen_state: bindgen.ClassState = .{},
da_rules: RuleList,

pub fn construct(
    _: bindgen.CallContext(BlockListConstructorSchema),
    _: bindgen.Args(BlockListConstructorSchema),
) bun.JSError!*BlockList {
    return create();
}

fn create() bun.OOM!*BlockList {
    const rule_list = try bun.default_allocator.create(RuleListType);
    errdefer bun.default_allocator.destroy(rule_list);
    rule_list.* = .{};
    const this = try bun.default_allocator.create(BlockList);
    this.* = .{ .da_rules = .adopt(rule_list) };
    return this;
}

pub fn memoryUsage(this: *const BlockList, _: bun.bindgen.MemoryUsageContext(.vm)) usize {
    const storage = this.da_rules.get();
    const io = bun.current_runtime.io();
    storage.mutex.lockUncancelable(io);
    defer storage.mutex.unlock(io);
    const shared_bytes = (@sizeOf(RuleListType) + storage.count * @sizeOf(RuleNode)) / @max(storage.ref_count.get(), 1);
    return (@sizeOf(BlockList) + shared_bytes) / @max(this.ref_count.get(), 1);
}

fn deinit(this: *BlockList) void {
    this.da_rules.deinit();
    bun.destroy(this);
}

pub fn isBlockList(
    _: bindgen.CallContext(BlockListIsBlockListSchema),
    args: bindgen.Args(BlockListIsBlockListSchema),
) bun.JSError!bool {
    return args.value != null;
}

pub fn addAddress(
    this: *BlockList,
    context: bindgen.CallContext(BlockListAddAddressSchema),
    args: bindgen.Args(BlockListAddAddressSchema),
) bindgen.CallError(BlockListAddAddressSchema)!void {
    const address = switch (args.address) {
        .socket_address => |value| value.get(SocketAddress).value.raw,
        .string => |value| try parseAddress(context, value, try familyValue(context, args.family)),
    };

    try this.insert(.{ .addr = address });
}

pub fn addRange(
    this: *BlockList,
    context: bindgen.CallContext(BlockListAddRangeSchema),
    args: bindgen.Args(BlockListAddRangeSchema),
) bindgen.CallError(BlockListAddRangeSchema)!void {
    const family = if (std.meta.activeTag(args.start) == .string or std.meta.activeTag(args.end) == .string)
        try familyValue(context, args.family)
    else
        SocketAddress.AF.INET;
    const start = switch (args.start) {
        .socket_address => |value| value.get(SocketAddress).value.raw,
        .string => |value| try parseAddress(context, value, family),
    };
    const end = switch (args.end) {
        .socket_address => |value| value.get(SocketAddress).value.raw,
        .string => |value| try parseAddress(context, value, family),
    };
    if (_compare(&start, &end)) |ord| {
        if (ord.compare(.gt)) {
            return context.fail(.start_after_end, {});
        }
    }
    try this.insert(.{ .range = .{ .start = start, .end = end } });
}

pub fn addSubnet(
    this: *BlockList,
    context: bindgen.CallContext(BlockListAddSubnetSchema),
    args: bindgen.Args(BlockListAddSubnetSchema),
) bindgen.CallError(BlockListAddSubnetSchema)!void {
    const network = switch (args.network) {
        .socket_address => |value| value.get(SocketAddress).value.raw,
        .string => |value| try parseAddress(context, value, try familyValue(context, args.family)),
    };
    const converted_prefix = try args.prefix.convert(context);
    const prefix_max: u8 = if (network.sin.family == std.posix.AF.INET) 32 else 128;
    const prefix_value = converted_prefix.value;
    if (prefix_value < 0 or prefix_value > prefix_max) {
        var message_buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "The value of \"prefix\" is out of range. It must be >= 0 and <= {d}. Received {d}",
            .{ prefix_max, prefix_value },
        ) catch unreachable;
        return context.fail(.prefix_out_of_range, try bindgen.DOMString.fromUTF8(message));
    }
    const prefix: u8 = @intCast(prefix_value);
    try this.insert(.{ .subnet = .{ .network = network, .prefix = prefix } });
}

fn insert(this: *BlockList, rule: Rule) bun.OOM!void {
    const node = try bun.default_allocator.create(RuleNode);
    errdefer bun.default_allocator.destroy(node);
    const storage = this.da_rules.get();
    const io = bun.current_runtime.io();
    storage.mutex.lockUncancelable(io);
    defer storage.mutex.unlock(io);
    const count = std.math.add(usize, storage.count, 1) catch return error.OutOfMemory;
    node.* = .{ .rule = rule, .next = storage.head };
    storage.head = .init(node);
    storage.count = count;
}

fn snapshot(this: *const BlockList, allocator: std.mem.Allocator) bun.OOM![]Rule {
    const storage = this.da_rules.get();
    const io = bun.current_runtime.io();
    storage.mutex.lockUncancelable(io);
    defer storage.mutex.unlock(io);
    const result = try allocator.alloc(Rule, storage.count);
    var next = storage.head.getOptional();
    for (result) |*rule| {
        const node = next orelse unreachable;
        rule.* = node.rule;
        next = node.next.getOptional();
    }
    bun.assert(next == null);
    return result;
}

pub fn check(
    this: *BlockList,
    context: bindgen.CallContext(BlockListCheckSchema),
    args: bindgen.Args(BlockListCheckSchema),
) bun.JSError!bool {
    var parsed_address: SocketAddress.sockaddr = undefined;
    const address = switch (args.address) {
        .socket_address => |value| &value.get(SocketAddress).value.raw,
        .string => |value| blk: {
            parsed_address = (SocketAddress.initFromAddressFamily(value, try familyValue(context, args.family)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidAddress => return false,
            }).value.raw;
            break :blk &parsed_address;
        },
    };
    const storage = this.da_rules.get();
    const io = bun.current_runtime.io();
    storage.mutex.lockUncancelable(io);
    defer storage.mutex.unlock(io);
    var next = storage.head.getOptional();
    while (next) |node| : (next = node.next.getOptional()) {
        const item = &node.rule;
        switch (item.*) {
            .addr => |*a| {
                const order = _compare(address, a) orelse continue;
                if (order.compare(.eq)) return true;
            },
            .range => |*r| {
                const os = _compare(address, &r.start) orelse continue;
                const oe = _compare(address, &r.end) orelse continue;
                if (os.compare(.gte) and oe.compare(.lte)) return true;
            },
            .subnet => |*s| {
                if (address.as_v4()) |ip_addr| if (s.network.as_v4()) |subnet_addr| {
                    const mask_addr: u32 = if (s.prefix == 0) 0 else @as(u32, std.math.maxInt(u32)) << @intCast(32 - s.prefix);
                    const ip_net: u32 = @byteSwap(ip_addr) & mask_addr;
                    const subnet_net: u32 = @byteSwap(subnet_addr) & mask_addr;
                    if (ip_net == subnet_net) return true;
                };
                if (address.sin.family == std.posix.AF.INET6 and s.network.sin.family == std.posix.AF.INET6) {
                    const ip_addr: u128 = @bitCast(address.sin6.addr);
                    const subnet_addr: u128 = @bitCast(s.network.sin6.addr);
                    const mask_addr: u128 = if (s.prefix == 0) 0 else @as(u128, std.math.maxInt(u128)) << @intCast(128 - s.prefix);
                    const ip_net: u128 = @byteSwap(ip_addr) & mask_addr;
                    const subnet_net: u128 = @byteSwap(subnet_addr) & mask_addr;
                    if (ip_net == subnet_net) return true;
                }
            },
        }
    }
    return false;
}

fn parseAddress(context: anytype, address: bindgen.DOMStringView, family: SocketAddress.AF) bun.bindgen.CallError(@TypeOf(context))!sockaddr {
    const parsed = SocketAddress.initFromAddressFamily(address, family) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidAddress => return context.fail(.invalid_address, {}),
    };
    return parsed.value.raw;
}

pub fn rules(
    this: *BlockList,
    _: bindgen.CallContext(BlockListRulesSchema),
    _: bindgen.Args(BlockListRulesSchema),
) bun.JSError!bindgen.Return(BlockListRulesSchema) {
    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var values: std.ArrayListUnmanaged([]const u8) = .empty;

    const rule_snapshot = try this.snapshot(allocator);
    try values.ensureTotalCapacity(allocator, rule_snapshot.len);
    for (rule_snapshot) |*rule| {
        const value = switch (rule.*) {
            .addr => |*a| value: {
                var buf: [SocketAddress.inet.INET6_ADDRSTRLEN]u8 = @splat(0);
                break :value try std.fmt.allocPrint(allocator, "Address: {s} {s}", .{ a.family().upper(), a.fmt(&buf) });
            },
            .range => |*r| value: {
                var buf_s: [SocketAddress.inet.INET6_ADDRSTRLEN]u8 = @splat(0);
                var buf_e: [SocketAddress.inet.INET6_ADDRSTRLEN]u8 = @splat(0);
                break :value try std.fmt.allocPrint(allocator, "Range: {s} {s}-{s}", .{ r.start.family().upper(), r.start.fmt(&buf_s), r.end.fmt(&buf_e) });
            },
            .subnet => |*s| value: {
                var buf: [SocketAddress.inet.INET6_ADDRSTRLEN]u8 = @splat(0);
                break :value try std.fmt.allocPrint(allocator, "Subnet: {s} {s}/{d}", .{ s.network.family().upper(), s.network.fmt(&buf), s.prefix });
            },
        };
        values.appendAssumeCapacity(value);
    }
    return try bindgen.Return(BlockListRulesSchema).fromUTF8Slices(values.items);
}

fn familyValue(context: anytype, family: anytype) bun.JSError!SocketAddress.AF {
    const value = family orelse return .INET;
    const converted = try value.convert(context);
    return switch (converted.value) {
        .ipv4 => .INET,
        .ipv6 => .INET6,
    };
}

pub fn structuredCloneShare(
    this: *const BlockList,
    _: bindgen.StructuredCloneContext(BlockListSchema),
) bun.JSError!RuleList {
    return this.da_rules.clone();
}

pub fn structuredCloneFromShared(
    _: bindgen.StructuredCloneContext(BlockListSchema),
    shared: bindgen.BorrowedNative(RuleListType, .any),
) bun.JSError!*BlockList {
    const this = try bun.default_allocator.create(BlockList);
    this.* = .{ .da_rules = .init(shared.get()) };
    return this;
}

pub const Rule = union(enum) {
    addr: sockaddr,
    range: struct { start: sockaddr, end: sockaddr },
    subnet: struct { network: sockaddr, prefix: u8 },
};

fn _compare(l: *const sockaddr, r: *const sockaddr) ?std.math.Order {
    if (l.as_v4()) |l_4| if (r.as_v4()) |r_4| return std.math.order(@byteSwap((l_4)), @byteSwap((r_4)));
    if (l.sin.family == std.posix.AF.INET6 and r.sin.family == std.posix.AF.INET6) return _compare_ipv6(&l.sin6, &r.sin6);
    return null;
}

fn _compare_ipv6(l: *const sockaddr.in6, r: *const sockaddr.in6) std.math.Order {
    return std.math.order(@byteSwap((@as(u128, @bitCast(l.addr)))), @byteSwap((@as(u128, @bitCast(r.addr)))));
}

const std = @import("std");
const bun = @import("bun");
const bindgen = bun.bindgen;

const RuleNode = struct {
    rule: Rule,
    next: bindgen.OwnedNative(RuleNode, .any) = .empty,

    pub fn destroy(first: *RuleNode) void {
        var next: ?*RuleNode = first;
        while (next) |node| {
            next = node.next.takeOptional();
            bun.default_allocator.destroy(node);
        }
    }
};

pub const RuleListType = struct {
    const RuleRefCount = bun.ptr.ThreadSafeRefCount(@This(), "ref_count", destroy, .{});
    pub const ref = RuleRefCount.ref;
    pub const deref = RuleRefCount.deref;

    ref_count: RuleRefCount = .init(),
    mutex: std.Io.Mutex = .init,
    head: bindgen.OwnedNative(RuleNode, .any) = .empty,
    count: usize = 0,

    fn destroy(list: *@This()) void {
        list.head.deinit();
        bun.destroy(list);
    }
};
const RuleList = bindgen.RefNative(RuleListType, .any);

const SocketAddress = @import("../../socket/SocketAddress.zig");
const BlockListBindingModule = bindgen.Module("BlockList");
const BlockListSchema = BlockListBindingModule.class("BlockList");
const BlockListConstructorSchema = BlockListSchema.constructor();
const BlockListAddAddressSchema = BlockListSchema.member("addAddress");
const BlockListAddRangeSchema = BlockListSchema.member("addRange");
const BlockListAddSubnetSchema = BlockListSchema.member("addSubnet");
const BlockListCheckSchema = BlockListSchema.member("check");
const BlockListRulesSchema = BlockListSchema.member("rules");
const BlockListIsBlockListSchema = BlockListSchema.member("isBlockList");
const BlockListClass = bindgen.Class(BlockListSchema, BlockList);

const sockaddr = SocketAddress.sockaddr;

comptime {
    _ = BlockListClass;
}
