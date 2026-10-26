//! JS testing/debugging bindings for the crash handler. Keeps
//! `src/crash_handler/` free of JSC types.

pub const js_bindings = struct {
    pub fn jsGetMachOImageZeroOffset(
        _: bun.bindgen.CallContext(GetMachOImageZeroOffsetSchema),
        _: bun.bindgen.Args(GetMachOImageZeroOffsetSchema),
    ) bun.JSError!bun.bindgen.Return(GetMachOImageZeroOffsetSchema) {
        if (!bun.Environment.isMac) return null;

        const header = std.c._dyld_get_image_header(0) orelse return null;
        const base_address = @intFromPtr(header);
        const vmaddr_slide = std.c._dyld_get_image_vmaddr_slide(0);

        return @intCast(base_address - vmaddr_slide);
    }

    pub fn jsSegfault(
        _: bun.bindgen.CallContext(SegfaultSchema),
        _: bun.bindgen.Args(SegfaultSchema),
    ) bun.JSError!void {
        @setRuntimeSafety(false);
        crash_handler.suppressCoreDumpsIfNecessary();
        const ptr: [*]align(1) u64 = @ptrFromInt(0xDEADBEEF);
        ptr[0] = 0xDEADBEEF;
        std.mem.doNotOptimizeAway(&ptr);
    }

    pub fn jsPanic(
        _: bun.bindgen.CallContext(PanicSchema),
        _: bun.bindgen.Args(PanicSchema),
    ) bun.JSError!void {
        crash_handler.suppressCoreDumpsIfNecessary();
        bun.crash_handler.panicImpl("invoked crashByPanic() handler", null, null);
    }

    pub fn jsRootError(
        _: bun.bindgen.CallContext(RootErrorSchema),
        _: bun.bindgen.Args(RootErrorSchema),
    ) bun.JSError!void {
        bun.crash_handler.handleRootError(error.Test, null);
    }

    pub fn jsOutOfMemory(
        _: bun.bindgen.CallContext(OutOfMemorySchema),
        _: bun.bindgen.Args(OutOfMemorySchema),
    ) bun.JSError!void {
        crash_handler.suppressCoreDumpsIfNecessary();
        bun.outOfMemory();
    }

    pub fn jsRaiseIgnoringPanicHandler(
        _: bun.bindgen.CallContext(RaiseIgnoringPanicHandlerSchema),
        _: bun.bindgen.Args(RaiseIgnoringPanicHandlerSchema),
    ) bun.JSError!void {
        crash_handler.suppressCoreDumpsIfNecessary();
        bun.Global.raiseIgnoringPanicHandler(.SIGSEGV);
    }

    pub fn jsGetFeaturesAsVLQ(
        _: bun.bindgen.CallContext(GetFeaturesAsVLQSchema),
        _: bun.bindgen.Args(GetFeaturesAsVLQSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        const bits = bun.analytics.packedFeatures();
        var buffer: [16]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        crash_handler.writeU64AsTwoVLQs(&writer, @bitCast(bits)) catch unreachable;
        return bun.bindgen.DOMString.fromUTF8(writer.buffered());
    }

    pub fn jsGetFeatureData(
        _: bun.bindgen.CallContext(GetFeatureDataSchema),
        _: bun.bindgen.Args(GetFeatureDataSchema),
    ) bun.JSError!bun.bindgen.Return(GetFeatureDataSchema) {
        var features = try CrashHandlerFeatureList.fromUTF8Slices(&bun.analytics.packed_features_list);
        errdefer features.deinit();
        var version = try bun.bindgen.DOMString.fromUTF8(Global.package_json_version);
        errdefer version.deinit();
        var revision = try bun.bindgen.DOMString.fromUTF8(bun.Environment.git_sha);
        errdefer revision.deinit();
        return .{
            .features = features,
            .version = version,
            .is_canary = bun.Environment.is_canary,
            .revision = revision,
            .generated_at = @max(bun.timespec.realNow().ms(), 0),
        };
    }
};

const std = @import("std");

const bun = @import("bun");
const Global = bun.Global;
const crash_handler = bun.crash_handler;
const CrashHandlerBindings = bun.bindgen.Module("CrashHandlerBindings");
const GetMachOImageZeroOffsetSchema = CrashHandlerBindings.function("getMachOImageZeroOffset");
const GetFeaturesAsVLQSchema = CrashHandlerBindings.function("getFeaturesAsVLQ");
const GetFeatureDataSchema = CrashHandlerBindings.function("getFeatureData");
const CrashHandlerFeatureList = bun.bindgen.ResultType(GetFeatureDataSchema.ReturnType.dictionary_fields[0].FieldType);
const SegfaultSchema = CrashHandlerBindings.function("segfault");
const PanicSchema = CrashHandlerBindings.function("panic");
const RootErrorSchema = CrashHandlerBindings.function("rootError");
const OutOfMemorySchema = CrashHandlerBindings.function("outOfMemory");
const RaiseIgnoringPanicHandlerSchema = CrashHandlerBindings.function("raiseIgnoringPanicHandler");
const GetMachOImageZeroOffsetBinding = bun.bindgen.Fn(GetMachOImageZeroOffsetSchema, js_bindings.jsGetMachOImageZeroOffset);
const GetFeaturesAsVLQBinding = bun.bindgen.Fn(GetFeaturesAsVLQSchema, js_bindings.jsGetFeaturesAsVLQ);
const GetFeatureDataBinding = bun.bindgen.Fn(GetFeatureDataSchema, js_bindings.jsGetFeatureData);
const SegfaultBinding = bun.bindgen.Fn(SegfaultSchema, js_bindings.jsSegfault);
const PanicBinding = bun.bindgen.Fn(PanicSchema, js_bindings.jsPanic);
const RootErrorBinding = bun.bindgen.Fn(RootErrorSchema, js_bindings.jsRootError);
const OutOfMemoryBinding = bun.bindgen.Fn(OutOfMemorySchema, js_bindings.jsOutOfMemory);
const RaiseIgnoringPanicHandlerBinding = bun.bindgen.Fn(RaiseIgnoringPanicHandlerSchema, js_bindings.jsRaiseIgnoringPanicHandler);

comptime {
    _ = GetMachOImageZeroOffsetBinding;
    _ = GetFeaturesAsVLQBinding;
    _ = GetFeatureDataBinding;
    _ = SegfaultBinding;
    _ = PanicBinding;
    _ = RootErrorBinding;
    _ = OutOfMemoryBinding;
    _ = RaiseIgnoringPanicHandlerBinding;
}
