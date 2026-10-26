pub const CallbackContext = opaque {};

pub const EventTag = enum(u8) {
    rename,
    change,
    @"error",
};

pub const ChangeKind = enum(u8) {
    rename,
    change,

    pub fn toEvent(this: ChangeKind, path: []const u8) Event {
        return switch (this) {
            inline else => |kind| @unionInit(Event, @tagName(kind), path),
        };
    }
};

pub const DuplicateFilter = struct {
    hash: u64 = 0,
    kind: ChangeKind = .change,
    timestamp_ms: u64 = 0,

    pub fn shouldEmit(this: *DuplicateFilter, hash: u64, timestamp_ms: u64, kind: ChangeKind) bool {
        if (this.timestamp_ms != 0 and
            timestamp_ms -| this.timestamp_ms <= 1 and
            this.kind == kind and
            this.hash == hash)
        {
            return false;
        }
        this.* = .{
            .hash = hash,
            .kind = kind,
            .timestamp_ms = timestamp_ms,
        };
        return true;
    }
};

/// Path and error storage is borrowed until the callback returns.
pub const Event = union(EventTag) {
    rename: []const u8,
    change: []const u8,
    @"error": bun.sys.Error,

    pub fn toOwned(this: Event) bun.OOM!OwnedEvent {
        return switch (this) {
            inline .rename, .change => |path, tag| @unionInit(
                OwnedEvent,
                @tagName(tag),
                try bun.default_allocator.dupe(u8, path),
            ),
            .@"error" => |err| .{ .@"error" = err.clone(bun.default_allocator) },
        };
    }
};

pub const OwnedEvent = union(EventTag) {
    rename: []u8,
    change: []u8,
    @"error": bun.sys.Error,

    pub fn deinit(this: *OwnedEvent) void {
        switch (this.*) {
            .rename, .change => |path| bun.default_allocator.free(path),
            .@"error" => |*err| err.deinit(),
        }
    }
};

pub const Callback = *const fn (context: *CallbackContext, event: Event, is_file: bool) void;
pub const UpdateEndCallback = *const fn (context: *CallbackContext) void;

const bun = @import("bun");
