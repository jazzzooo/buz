/// The process owns these mapped executable pages; callers borrow them until exit.
pub fn get() error{InvalidStandaloneExecutable}!?[]const u8 {
    var data: [*c]const u8 = null;
    var length: usize = 0;
    return switch (c.bun_embedded_data(&data, &length)) {
        c.BUN_EMBEDDED_ABSENT => null,
        c.BUN_EMBEDDED_READY => data[0..length],
        c.BUN_EMBEDDED_INVALID => error.InvalidStandaloneExecutable,
        else => @panic("executable image reader returned an unknown status"),
    };
}

const c = @import("embedded-data");
