const InspectorBunFrontendDevServerAgentHandle = opaque {};

pub const BunFrontendDevServerAgent = struct {
    next_inspector_connection_id: i32 = 0,
    handle: ?*InspectorBunFrontendDevServerAgentHandle = null,

    pub fn nextConnectionID(this: *BunFrontendDevServerAgent) i32 {
        const id = this.next_inspector_connection_id;
        this.next_inspector_connection_id +%= 1;
        return id;
    }

    pub fn isEnabled(this: *const BunFrontendDevServerAgent) bool {
        return this.handle != null;
    }

    pub fn notifyClientConnected(this: *const BunFrontendDevServerAgent, devServerId: DebuggerId, connectionId: i32) void {
        if (this.handle) |handle| {
            bun.bindgen.Engine(InspectorDevServerClientConnectedShim).call(.{
                .agent = @ptrCast(handle),
                .devServerId = devServerId.get(),
                .connectionId = connectionId,
            });
        }
    }

    pub fn notifyClientDisconnected(this: *const BunFrontendDevServerAgent, devServerId: DebuggerId, connectionId: i32) void {
        if (this.handle) |handle| {
            bun.bindgen.Engine(InspectorDevServerClientDisconnectedShim).call(.{
                .agent = @ptrCast(handle),
                .devServerId = devServerId.get(),
                .connectionId = connectionId,
            });
        }
    }

    pub fn notifyBundleStart(this: *const BunFrontendDevServerAgent, devServerId: DebuggerId, triggerFiles: []bun.String) bun.OOM!void {
        if (this.handle) |handle| {
            var bound_trigger_files = try bun.bindgen.OwnedNativeSlice(bun.bindgen.DOMString, .vm).Builder.init(triggerFiles.len);
            defer bound_trigger_files.deinit();
            for (triggerFiles) |trigger_file| {
                bound_trigger_files.appendOwned(try bun.bindgen.DOMString.fromBunString(trigger_file.clone()));
            }

            const File = std.meta.Elem(bun.bindgen.EngineArgumentType(InspectorDevServerBundleStartShim, "triggerFiles"));
            const files = try bun.default_allocator.alloc(File, triggerFiles.len);
            defer bun.default_allocator.free(files);
            for (bound_trigger_files.slice(), files) |*file, *operand| operand.* = file.operand();
            try bun.bindgen.Engine(InspectorDevServerBundleStartShim).call(.{
                .agent = @ptrCast(handle),
                .devServerId = devServerId.get(),
                .triggerFiles = files,
            });
        }
    }

    pub fn notifyBundleComplete(this: *const BunFrontendDevServerAgent, devServerId: DebuggerId, durationMs: f64) void {
        if (this.handle) |handle| {
            bun.bindgen.Engine(InspectorDevServerBundleCompleteShim).call(.{
                .agent = @ptrCast(handle),
                .devServerId = devServerId.get(),
                .durationMs = durationMs,
            });
        }
    }

    pub fn notifyBundleFailed(this: *const BunFrontendDevServerAgent, devServerId: DebuggerId, buildErrorsPayloadBase64: *bun.String) void {
        if (this.handle) |handle| {
            var payload = bun.bindgen.DOMString.fromBunString(buildErrorsPayloadBase64.*.clone()) catch bun.outOfMemory();
            defer payload.deinit();
            bun.bindgen.Engine(InspectorDevServerBundleFailedShim).call(.{
                .agent = @ptrCast(handle),
                .devServerId = devServerId.get(),
                .payload = payload.operand(),
            });
        }
    }

    pub fn notifyClientNavigated(
        this: *const BunFrontendDevServerAgent,
        devServerId: DebuggerId,
        connectionId: i32,
        url: *bun.String,
        routeBundleId: ?DevServer.RouteBundle.Index,
    ) void {
        if (this.handle) |handle| {
            var bound_url = bun.bindgen.DOMString.fromBunString(url.*.clone()) catch bun.outOfMemory();
            defer bound_url.deinit();
            bun.bindgen.Engine(InspectorDevServerClientNavigatedShim).call(.{
                .agent = @ptrCast(handle),
                .devServerId = devServerId.get(),
                .connectionId = connectionId,
                .url = bound_url.operand(),
                .routeBundleId = if (routeBundleId) |id| id.get() else null,
            });
        }
    }

    pub fn notifyClientErrorReported(
        this: *const BunFrontendDevServerAgent,
        devServerId: DebuggerId,
        clientErrorPayloadBase64: *bun.String,
    ) void {
        if (this.handle) |handle| {
            var payload = bun.bindgen.DOMString.fromBunString(clientErrorPayloadBase64.*.clone()) catch bun.outOfMemory();
            defer payload.deinit();
            bun.bindgen.Engine(InspectorDevServerClientErrorReportedShim).call(.{
                .agent = @ptrCast(handle),
                .devServerId = devServerId.get(),
                .payload = payload.operand(),
            });
        }
    }

    pub fn notifyGraphUpdate(this: *const BunFrontendDevServerAgent, devServerId: DebuggerId, visualizerPayloadBase64: *bun.String) void {
        if (this.handle) |handle| {
            var payload = bun.bindgen.DOMString.fromBunString(visualizerPayloadBase64.*.clone()) catch bun.outOfMemory();
            defer payload.deinit();
            bun.bindgen.Engine(InspectorDevServerGraphUpdateShim).call(.{
                .agent = @ptrCast(handle),
                .devServerId = devServerId.get(),
                .payload = payload.operand(),
            });
        }
    }

    pub fn notifyConsoleLog(this: BunFrontendDevServerAgent, devServerId: DebuggerId, kind: DevServerProtocol.ConsoleLogKind, data: *bun.String) void {
        if (this.handle) |handle| {
            var bound_data = bun.bindgen.DOMString.fromBunString(data.*.clone()) catch bun.outOfMemory();
            defer bound_data.deinit();
            bun.bindgen.Engine(InspectorDevServerConsoleLogShim).call(.{
                .agent = @ptrCast(handle),
                .devServerId = devServerId.get(),
                .kind = @backingInt(kind),
                .data = bound_data.operand(),
            });
        }
    }
};

fn bindSetEnabled(args: bun.bindgen.Args(SetInspectorBunFrontendDevServerAgentSchema)) bun.bindgen.Return(SetInspectorBunFrontendDevServerAgentSchema) {
    const agent: *InspectorBunFrontendDevServerAgentHandle = @ptrCast(args.agent);
    if (jsc.VirtualMachine.get().debugger) |*debugger| {
        if (args.enabled) {
            debugger.frontend_dev_server_agent.handle = agent;
        } else if (debugger.frontend_dev_server_agent.handle == agent) {
            debugger.frontend_dev_server_agent.handle = null;
        }
    }
}

const bun = @import("bun");
const DevServerProtocol = @import("../../bake/DevServerProtocol.zig");
const jsc = bun.jsc;
const DevServer = bun.bake.DevServer;
const DebuggerId = jsc.Debugger.DebuggerId;
const InspectorAgentBindings = bun.bindgen.Module("inspector_agents");
const InspectorDevServerClientConnectedShim = InspectorAgentBindings.engineShim("inspectorDevServerClientConnected");
const InspectorDevServerClientDisconnectedShim = InspectorAgentBindings.engineShim("inspectorDevServerClientDisconnected");
const InspectorDevServerBundleStartShim = InspectorAgentBindings.engineShim("inspectorDevServerBundleStart");
const InspectorDevServerBundleCompleteShim = InspectorAgentBindings.engineShim("inspectorDevServerBundleComplete");
const InspectorDevServerBundleFailedShim = InspectorAgentBindings.engineShim("inspectorDevServerBundleFailed");
const InspectorDevServerClientNavigatedShim = InspectorAgentBindings.engineShim("inspectorDevServerClientNavigated");
const InspectorDevServerClientErrorReportedShim = InspectorAgentBindings.engineShim("inspectorDevServerClientErrorReported");
const InspectorDevServerGraphUpdateShim = InspectorAgentBindings.engineShim("inspectorDevServerGraphUpdate");
const InspectorDevServerConsoleLogShim = InspectorAgentBindings.engineShim("inspectorDevServerConsoleLog");
const SetInspectorBunFrontendDevServerAgentSchema = InspectorAgentBindings.nativeExport("setInspectorBunFrontendDevServerAgent");
const SetInspectorBunFrontendDevServerAgentBinding = bun.bindgen.Fn(SetInspectorBunFrontendDevServerAgentSchema, bindSetEnabled);

comptime {
    _ = SetInspectorBunFrontendDevServerAgentBinding;
}

const std = @import("std");
