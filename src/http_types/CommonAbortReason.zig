pub const CommonAbortReason = enum(u8) {
    Timeout = 1,
    UserAbort = 2,
    ConnectionClosed = 3,

    pub fn toBinding(this: CommonAbortReason, comptime BindingReason: type) BindingReason {
        return switch (this) {
            .Timeout => .Timeout,
            .UserAbort => .UserAbort,
            .ConnectionClosed => .ConnectionClosed,
        };
    }
};
