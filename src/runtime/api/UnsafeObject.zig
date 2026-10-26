pub fn gcAggressionLevel(
    _: bun.bindgen.CallContext(GcAggressionLevelSchema),
    args: bun.bindgen.Args(GcAggressionLevelSchema),
) bun.JSError!i32 {
    return bun.current_runtime.configureGarbageCollectionAggression(args.value);
}

pub fn arrayBufferToString(
    _: bun.bindgen.CallContext(ArrayBufferToStringSchema),
    args: bun.bindgen.Args(ArrayBufferToStringSchema),
) bun.JSError!bun.bindgen.DOMString {
    const bytes = args.value.unsafePtr("the generated entry frame retains the byte lease while the string copies these bytes");
    if (args.value.elementSize() == 2) {
        const aligned_bytes: []align(@alignOf(u16)) const u8 = @alignCast(bytes);
        const units = std.mem.bytesAsSlice(u16, aligned_bytes);
        return bun.bindgen.DOMString.fromUTF16(units);
    }
    return bun.bindgen.DOMString.fromUTF8(bytes);
}

fn dump_mimalloc(
    _: bun.bindgen.CallContext(MimallocDumpSchema),
    _: bun.bindgen.Args(MimallocDumpSchema),
) bun.JSError!void {
    bun.current_runtime.dumpAllocatorStats();
    if (bun.heap_breakdown.enabled) {
        bun.bindgen.Engine(DumpMallocZoneStatsSchema).call(.{});
    }
}

const bun = @import("bun");
const std = @import("std");

const UnsafeObjectBindings = bun.bindgen.Module("UnsafeObject");
const GcAggressionLevelSchema = UnsafeObjectBindings.function("gcAggressionLevel");
const ArrayBufferToStringSchema = UnsafeObjectBindings.function("arrayBufferToString");
const MimallocDumpSchema = UnsafeObjectBindings.function("mimallocDump");
const DumpMallocZoneStatsSchema = UnsafeObjectBindings.engineShim("dumpMallocZoneStats");
const GcAggressionLevelBinding = bun.bindgen.Fn(GcAggressionLevelSchema, gcAggressionLevel);
const ArrayBufferToStringBinding = bun.bindgen.Fn(ArrayBufferToStringSchema, arrayBufferToString);
const MimallocDumpBinding = bun.bindgen.Fn(MimallocDumpSchema, dump_mimalloc);

comptime {
    _ = GcAggressionLevelBinding;
    _ = ArrayBufferToStringBinding;
    _ = MimallocDumpBinding;
}
