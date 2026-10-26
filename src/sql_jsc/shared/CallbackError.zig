const bun = @import("bun");
const bindgen = bun.bindgen;

pub fn pending(global: *bun.jsc.JSGlobalObject) ?bun.JSError {
    return switch (global.pendingExceptionKind()) {
        .none => null,
        .other => error.JSError,
        .termination => error.JSTerminated,
    };
}

pub fn takeRoot(global: *bun.jsc.JSGlobalObject, failure: bun.JSError) bun.JSError!bindgen.Root {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var value = try scope.takeThrownValue(failure);
    defer value.deinit();
    return value.toRoot();
}

pub fn systemErrorRoot(global: *bun.jsc.JSGlobalObject, input: bindgen.SystemError.Init) bun.JSError!bindgen.Root {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var value = try bindgen.SystemError.createErrorInstance(&scope, input);
    defer value.deinit();
    return value.toRoot();
}
