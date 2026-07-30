const KEventWatcher = @This();

pub const EventListIndex = u32;

// Everything being watched
eventlist_index: EventListIndex = 0,

fd: bun.FD.Optional = .none,

const changelist_count = 128;
const shutdown_ident = std.math.maxInt(usize);

pub fn init(this: *KEventWatcher, _: []const u8) !void {
    const fd = try bun.sys.kqueue().unwrap();
    errdefer fd.close();
    if (fd.cast() == 0) return error.KQueueError;

    var change = [_]KEvent{.{
        .ident = shutdown_ident,
        .filter = std.c.EVFILT.USER,
        .flags = std.c.EV.ADD | std.c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = shutdown_ident,
    }};
    const result = std.posix.system.kevent(fd.native(), change[0..].ptr, change.len, change[0..].ptr, 0, null);
    if (std.posix.errno(result) != .SUCCESS) return error.KQueueError;

    this.fd = .init(fd);
}

pub fn stop(this: *KEventWatcher) void {
    if (this.fd.take()) |fd| {
        fd.close();
    }
}

pub fn requestStop(this: *KEventWatcher) void {
    const fd = this.fd.unwrap() orelse return;
    var change = [_]KEvent{.{
        .ident = shutdown_ident,
        .filter = std.c.EVFILT.USER,
        .flags = 0,
        .fflags = std.c.NOTE.TRIGGER,
        .data = 0,
        .udata = shutdown_ident,
    }};
    _ = std.posix.system.kevent(fd.native(), change[0..].ptr, change.len, change[0..].ptr, 0, null);
}

pub fn deinit(this: *KEventWatcher) void {
    this.stop();
}

pub fn watchEventFromKEvent(kevent: KEvent) Watcher.Event {
    return .{
        .op = .{
            .delete = (kevent.fflags & std.c.NOTE.DELETE) > 0,
            .metadata = (kevent.fflags & std.c.NOTE.ATTRIB) > 0,
            .rename = (kevent.fflags & (std.c.NOTE.RENAME | std.c.NOTE.LINK)) > 0,
            .write = (kevent.fflags & std.c.NOTE.WRITE) > 0,
        },
        .index = @truncate(kevent.udata),
    };
}

pub fn watchLoopCycle(this: *Watcher) std.Io.Cancelable!bun.sys.Maybe(void) {
    const fd: bun.FD = this.platform.fd.unwrap() orelse
        @panic("KEventWatcher has an invalid file descriptor");

    var changelist_array: [changelist_count]KEvent = undefined;
    const changelist = &changelist_array;

    defer Output.flush();

    var count = switch (try wait(
        this.io,
        fd,
        changelist,
        null,
    )) {
        .result => |result| result,
        .err => |err| return .{ .err = err },
    };

    // Give the events more time to coalesce.
    if (count < changelist_count / 2) {
        try this.io.sleep(.fromNanoseconds(100_000), .awake);
        const extra = switch (try wait(
            this.io,
            fd,
            changelist[count..],
            &.{ .sec = 0, .nsec = 0 },
        )) {
            .result => |result| result,
            .err => |err| return .{ .err = err },
        };
        count += extra;
    }

    const changes = changelist[0..count];
    var watchevents = this.watch_events[0..changes.len];
    var out_len: usize = 0;
    var previous_udata: ?usize = null;
    for (changes) |event| {
        if (event.filter == std.c.EVFILT.USER and event.ident == shutdown_ident) continue;

        const new = watchEventFromKEvent(event);
        if (previous_udata) |udata| {
            if (udata == event.udata) {
                watchevents[out_len - 1].merge(new);
                continue;
            }
        }

        watchevents[out_len] = new;
        previous_udata = event.udata;
        out_len += 1;
    }
    watchevents = watchevents[0..out_len];

    this.mutex.lockUncancelable(this.io);
    defer this.mutex.unlock(this.io);
    if (this.running.load(.acquire)) {
        this.writeTraceEvents(watchevents, this.changed_filepaths[0..watchevents.len]);
        this.onFileUpdate(this.ctx, watchevents, this.changed_filepaths[0..watchevents.len], this.watchlist);
    }

    return .success;
}

fn wait(
    io: std.Io,
    fd: bun.FD,
    events: []KEvent,
    timeout: ?*const std.posix.timespec,
) std.Io.Cancelable!bun.sys.Maybe(usize) {
    while (true) {
        const count = std.posix.system.kevent(
            fd.native(),
            events.ptr,
            0,
            events.ptr,
            @intCast(events.len),
            timeout,
        );
        switch (std.posix.errno(count)) {
            .SUCCESS => return .{ .result = @intCast(count) },
            .INTR => {
                try io.checkCancel();
                continue;
            },
            else => |err| return .{ .err = .{
                .errno = @truncate(@backingInt(err)),
                .syscall = .watch,
            } },
        }
    }
}

const std = @import("std");
const KEvent = std.c.Kevent;

const bun = @import("bun");
const Output = bun.Output;
const Watcher = bun.Watcher;
