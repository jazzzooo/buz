const bun = @import("bun");
const ExpectState = @import("./State.zig");
const MatcherErrorEngine = @import("./MatcherErrorEngine.zig");

const bindgen = bun.bindgen;

pub fn process(
    custom_label: bun.String,
    flags: ExpectState.Flags,
    context: anytype,
    value: bindgen.EngineValueView,
    matcher_name: anytype,
    matcher_arguments: anytype,
    comptime silent: bool,
) bun.JSError!(if (silent) ?bindgen.EngineValueResult else bindgen.EngineValueResult) {
    switch (flags.promise) {
        inline .resolves, .rejects => |resolution| {
            const promise_result = (try context.engineIn("promises", "jsValueAsPromise").call(.{
                .value = value.operand(context).asEngine(),
            })) orelse {
                if (comptime silent) return null;
                return MatcherErrorEngine.throwPrettyValue(
                    context,
                    custom_label,
                    matcher_name,
                    matcher_arguments,
                    flags,
                    "Expected promise<r>\nReceived: <red>{f}<r>\n",
                    value.toResult(),
                );
            };
            const settlement = (try context.waitForPromiseResult(promise_result.operand(context).asPromise(), null)).?;
            const settled_result = switch (settlement) {
                inline else => |result| result,
            };
            const matched = switch (settlement) {
                .fulfilled => resolution == .resolves,
                .rejected => resolution == .rejects,
            };
            if (matched) return settled_result;
            if (comptime silent) return null;

            const message = switch (resolution) {
                .rejects => "Expected promise that rejects<r>\nReceived promise that resolved: <red>{f}<r>\n",
                .resolves => "Expected promise that resolves<r>\nReceived promise that rejected: <red>{f}<r>\n",
                .none => unreachable,
            };
            return MatcherErrorEngine.throwPrettyValue(
                context,
                custom_label,
                matcher_name,
                matcher_arguments,
                flags,
                message,
                settled_result,
            );
        },
        .none => return value.toResult(),
    }
}
