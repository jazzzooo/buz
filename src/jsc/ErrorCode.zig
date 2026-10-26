const ErrorCodeInt = u16;

pub const ErrorCode = enum(ErrorCodeInt) {
    _,

    pub inline fn from(code: anyerror) ErrorCode {
        return @as(ErrorCode, @fromBackingInt(@intCast(@intFromError(code))));
    }

    pub inline fn toError(self: ErrorCode) anyerror {
        return @errorFromInt(@backingInt(self));
    }

    pub const Type = ErrorCodeInt;
};
