pub const EventType = enum(u8) {
    Event,
    MessageEvent,
    CloseEvent,
    ErrorEvent,
    OpenEvent,
    unknown = 254,
    _,

    pub const map = bun.ComptimeStringMap(EventType, .{
        .{ EventType.Event.label(), EventType.Event },
        .{ EventType.MessageEvent.label(), EventType.MessageEvent },
        .{ EventType.CloseEvent.label(), EventType.CloseEvent },
        .{ EventType.ErrorEvent.label(), EventType.ErrorEvent },
        .{ EventType.OpenEvent.label(), EventType.OpenEvent },
    });

    pub fn label(event_type: EventType) []const u8 {
        return switch (event_type) {
            .Event => "event",
            .MessageEvent => "message",
            .CloseEvent => "close",
            .ErrorEvent => "error",
            .OpenEvent => "open",
            else => "event",
        };
    }
};

const bun = @import("bun");
