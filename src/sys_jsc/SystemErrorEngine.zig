//! JSC bridge for `bun.sys.Error`. Keeps `src/sys/` free of JSC types.

pub fn throwSysError(this: Error, global: *jsc.JSGlobalObject) bun.JSError {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var result = try bun.bindgen.SystemError.createSysErrorInstance(&scope, this);
    defer result.deinit();
    return result.throwException(&scope);
}

pub fn toRoot(this: Error, ptr: *jsc.JSGlobalObject) bun.JSError!bun.bindgen.Root {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(ptr);
    defer scope.deinit();
    var result = try bun.bindgen.SystemError.createSysErrorInstance(&scope, this);
    defer result.deinit();
    return result.toRoot();
}

pub fn systemErrorToRoot(value: SystemError, global: *jsc.JSGlobalObject) bun.JSError!bun.bindgen.Root {
    defer value.deref();
    var payload = try bun.bindgen.SystemError.fromSystemError(&value);
    defer payload.deinit();
    return retainPayload(&payload, global);
}

fn retainPayload(payload: *const bun.bindgen.SystemError, global: *jsc.JSGlobalObject) bun.JSError!bun.bindgen.Root {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var result = try payload.toErrorInstance(&scope);
    defer result.deinit();
    return result.toRoot();
}

pub fn throwSystemError(value: SystemError, global: *jsc.JSGlobalObject) bun.JSError {
    defer value.deref();
    var payload = try bun.bindgen.SystemError.fromSystemError(&value);
    defer payload.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var result = try payload.toErrorInstance(&scope);
    defer result.deinit();
    return result.throwException(&scope);
}

pub const TestingAPIs = struct {
    /// Exercises Error.name() with from_libuv=true so tests can feed the
    /// negated-UV-code errno values that node_fs.zig stores and verify the
    /// integer overflow at translateUVErrorToE(-code) is fixed. Windows-only.
    pub fn sysErrorNameFromLibuv(
        _: bun.bindgen.CallContext(SysErrorNameFromLibuvSchema),
        args: bun.bindgen.Args(SysErrorNameFromLibuvSchema),
    ) bun.JSError!?bun.bindgen.DOMString {
        if (comptime !Environment.isWindows) return null;
        const code = std.math.cast(Error.Int, args.code) orelse
            return try bun.bindgen.DOMString.fromUTF8("UNKNOWN");
        const err: Error = .{
            .errno = code,
            .syscall = .open,
            .from_libuv = true,
        };
        return try bun.bindgen.DOMString.fromUTF8(err.name());
    }

    /// Exposes libuv -> `bun.sys.E` translation so tests can feed out-of-range
    /// negative values and verify it does not panic. Windows-only.
    pub fn translateUVErrorToE(
        _: bun.bindgen.CallContext(TranslateUVErrorToESchema),
        args: bun.bindgen.Args(TranslateUVErrorToESchema),
    ) bun.JSError!?bun.bindgen.DOMString {
        if (comptime !Environment.isWindows) return null;
        const result = bun.windows.libuv.translateUVErrorToE(args.code);
        return try bun.bindgen.DOMString.fromUTF8(@tagName(result));
    }

    pub fn translateNtStatusToE(
        _: bun.bindgen.CallContext(TranslateNtStatusToESchema),
        args: bun.bindgen.Args(TranslateNtStatusToESchema),
    ) bun.JSError!?bun.bindgen.DOMString {
        if (comptime !Environment.isWindows) return null;
        const status: std.os.windows.NTSTATUS = @fromBackingInt(args.status);
        const result = bun.sys.SystemErrno.fromNtStatus(status).toE();
        return try bun.bindgen.DOMString.fromUTF8(@tagName(result));
    }

    /// Verifies `bun.sys.Sigaction`'s layout matches the host libc by
    /// round-tripping a known handler through `sigaction(2)`. If the struct
    /// layout disagrees with libc (as `std.posix.Sigaction` does on Android
    /// bionic — `sa_flags` first, 8-byte `sigset_t`), libc reads/writes the
    /// fields at the wrong offsets and the returned handler/flags won't match
    /// what we installed. Returns `{ installed, readback }` for the test to
    /// compare. POSIX-only.
    pub fn sigactionLayout(
        _: bun.bindgen.CallContext(SigactionLayoutSchema),
        _: bun.bindgen.Args(SigactionLayoutSchema),
    ) bun.JSError!bun.bindgen.Return(SigactionLayoutSchema) {
        if (comptime !Environment.isPosix) return null;

        const posix = std.posix;
        const sentry = struct {
            fn handler(_: std.posix.SIG) callconv(.c) void {}
        };
        var mask = bun.sys.sigemptyset();
        bun.sys.sigaddset(&mask, posix.SIG.USR2);
        const act = bun.sys.Sigaction{
            .handler = .{ .handler = &sentry.handler },
            .mask = mask,
            .flags = posix.SA.RESTART,
        };
        var prev: bun.sys.Sigaction = undefined;
        var readback: bun.sys.Sigaction = undefined;
        bun.sys.sigaction(posix.SIG.USR2, &act, &prev);
        bun.sys.sigaction(posix.SIG.USR2, null, &readback);
        bun.sys.sigaction(posix.SIG.USR2, &prev, null);

        return .{
            .installed = .{
                .handler = @floatFromInt(@intFromPtr(&sentry.handler)),
                .flags = @floatFromInt(act.flags & posix.SA.RESTART),
            },
            .readback = .{
                .handler = @floatFromInt(@intFromPtr(readback.handler.handler)),
                .flags = @floatFromInt(readback.flags & posix.SA.RESTART),
            },
            .size_of = @as(f64, @floatFromInt(@sizeOf(bun.sys.Sigaction))),
        };
    }
};

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const jsc = bun.jsc;
const Error = bun.sys.Error;
const SystemError = bun.sys.SystemError;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const SysErrorNameFromLibuvSchema = InternalTestingBindings.function("sysErrorNameFromLibuv");
const TranslateUVErrorToESchema = InternalTestingBindings.function("translateUVErrorToE");
const TranslateNtStatusToESchema = InternalTestingBindings.function("translateNtStatusToE");
const SigactionLayoutSchema = InternalTestingBindings.function("sigactionLayout");
const SysErrorNameFromLibuvBinding = bun.bindgen.Fn(SysErrorNameFromLibuvSchema, TestingAPIs.sysErrorNameFromLibuv);
const TranslateUVErrorToEBinding = bun.bindgen.Fn(TranslateUVErrorToESchema, TestingAPIs.translateUVErrorToE);
const TranslateNtStatusToEBinding = bun.bindgen.Fn(TranslateNtStatusToESchema, TestingAPIs.translateNtStatusToE);
const SigactionLayoutBinding = bun.bindgen.Fn(SigactionLayoutSchema, TestingAPIs.sigactionLayout);

comptime {
    _ = SysErrorNameFromLibuvBinding;
    _ = TranslateUVErrorToEBinding;
    _ = TranslateNtStatusToEBinding;
    _ = SigactionLayoutBinding;
}
