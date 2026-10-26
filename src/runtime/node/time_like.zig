const time_like = @import("../../sys/time_like.zig");

pub const TimeLike = time_like.TimeLike;

pub fn fromBindgen(seconds: f64) TimeLike {
    return time_like.fromSecondsOrOmit(seconds);
}
