pub const StdioKind = enum {
    stdin,
    stdout,
    stderr,

    pub fn toFd(kind: StdioKind) bun.FD {
        return switch (kind) {
            .stdin => .stdin(),
            .stdout => .stdout(),
            .stderr => .stderr(),
        };
    }
};

const bun = @import("bun");
