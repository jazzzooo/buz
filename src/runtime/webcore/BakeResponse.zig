const SSRKind = bun.bindgen.EngineArgumentType(BakeResponseBindings.engineShim("createForSSR"), "kind");

fn toResultForSSR(context: anytype, this: *Response, kind: SSRKind) bun.JSError!Response.Ref {
    this.calculateEstimatedByteSize();
    const operation = context.engineIn("BakeResponse", "createForSSR");
    const EngineArgs = @TypeOf(operation).Args;
    var args: EngineArgs = .{
        .response = @FieldType(EngineArgs, "response").initNative(this),
        .kind = kind,
    };
    return (try operation.call(&args)).toOwned();
}

fn releaseNativeResponse(
    args: bun.bindgen.Args(ReleaseNativeResponseSchema),
) bun.bindgen.Return(ReleaseNativeResponseSchema) {
    const response: *Response = @ptrCast(@alignCast(args.response));
    response.unref();
}

fn constructError(
    context: bun.bindgen.CallContext(ConstructErrorSchema),
    _: bun.bindgen.Args(ConstructErrorSchema),
) bun.JSError!bun.bindgen.Return(ConstructErrorSchema) {
    return (try Response.constructError()).toResult(context);
}

fn constructorCall(
    context: bun.bindgen.CallContext(ConstructorCallSchema),
    args: bun.bindgen.Args(ConstructorCallSchema),
) bun.bindgen.CallError(ConstructorCallSchema)!bun.bindgen.Return(ConstructorCallSchema) {
    return (try context.engineIn("BakeResponse", "construct").call(.{
        .body = if (args.body) |optional_value| optional_value.operand(context).asEngine() else null,
        .init = if (args.init) |optional_value| optional_value.operand(context).asAny() else null,
        .newTarget = null,
    })).toOwned();
}

fn constructorConstruct(
    context: bun.bindgen.CallContext(ConstructorConstructSchema),
    args: bun.bindgen.Args(ConstructorConstructSchema),
) bun.bindgen.CallError(ConstructorConstructSchema)!bun.bindgen.Return(ConstructorConstructSchema) {
    return (try context.engineIn("BakeResponse", "construct").call(.{
        .body = if (args.body) |optional_value| optional_value.operand(context).asEngine() else null,
        .init = if (args.init) |optional_value| optional_value.operand(context).asAny() else null,
        .newTarget = args.bindingNewTarget.operand(context),
    })).toOwned();
}

fn constructJSON(
    context: bun.bindgen.CallContext(ConstructJSONSchema),
    args: bun.bindgen.Args(ConstructJSONSchema),
) bun.bindgen.CallError(ConstructJSONSchema)!bun.bindgen.Return(ConstructJSONSchema) {
    const response = try Response.constructJSONForContext(context, args);
    return response.toResult(context);
}

fn constructRedirect(
    context: bun.bindgen.CallContext(ConstructRedirectSchema),
    args: bun.bindgen.Args(ConstructRedirectSchema),
) bun.bindgen.CallError(ConstructRedirectSchema)!bun.bindgen.Return(ConstructRedirectSchema) {
    const response = try Response.constructRedirectForContext(context, args);
    var response_owned = true;
    defer if (response_owned) response.unref();

    if (try context.engineIn("BakeResponse", "validateStreamingMode").call(.{ .caller = .redirect })) {
        response_owned = false;
        return toResultForSSR(context, response, .redirect);
    }

    response_owned = false;
    return response.toResult(context);
}

/// This function is only available on JSBakeResponse
fn constructRender(
    context: bun.bindgen.CallContext(ConstructRenderSchema),
    args: bun.bindgen.Args(ConstructRenderSchema),
) bun.bindgen.CallError(ConstructRenderSchema)!bun.bindgen.Return(ConstructRenderSchema) {
    if (!try context.engineIn("BakeResponse", "validateStreamingMode").call(.{ .caller = .render })) {
        return context.fail(.dev_server_only, {});
    }

    const path_utf8 = try args.path.toUTF8(bun.default_allocator);
    defer path_utf8.deinit();

    const response = try Response.create(Response.init(
        .{
            .status_code = 200,
            .headers = headers: {
                var headers = try bun.webcore.FetchHeaders.createEmpty();
                errdefer headers.deinit();
                try context.engineIn("fetch_headers", "fetchHeadersPut").call(.{
                    .headers = headers.get(),
                    .name = .Location,
                    .value = bun.bindgen.BytesOperand.fromSlice(path_utf8.slice()),
                });
                break :headers headers;
            },
        },
        .{ .value = .Empty },
        .empty(),
        false,
    ));

    return toResultForSSR(context, response, .render);
}

const std = @import("std");

const bun = @import("bun");
const Response = bun.webcore.Response;

const BakeResponseBindings = bun.bindgen.Module("BakeResponse");
const ConstructorCallSchema = BakeResponseBindings.function("constructorCall");
const ConstructorConstructSchema = BakeResponseBindings.function("constructorConstruct");
const ConstructErrorSchema = BakeResponseBindings.function("constructError");
const ConstructJSONSchema = BakeResponseBindings.function("constructJSON");
const ConstructRedirectSchema = BakeResponseBindings.function("constructRedirect");
const ConstructRenderSchema = BakeResponseBindings.function("constructRender");
const ReleaseNativeResponseSchema = BakeResponseBindings.nativeExport("releaseNativeResponse");
const ConstructorCallBinding = bun.bindgen.Fn(ConstructorCallSchema, constructorCall);
const ConstructorConstructBinding = bun.bindgen.Fn(ConstructorConstructSchema, constructorConstruct);
const ConstructErrorBinding = bun.bindgen.Fn(ConstructErrorSchema, constructError);
const ConstructJSONBinding = bun.bindgen.Fn(ConstructJSONSchema, constructJSON);
const ConstructRedirectBinding = bun.bindgen.Fn(ConstructRedirectSchema, constructRedirect);
const ConstructRenderBinding = bun.bindgen.Fn(ConstructRenderSchema, constructRender);
const ReleaseNativeResponseBinding = bun.bindgen.Fn(ReleaseNativeResponseSchema, releaseNativeResponse);

comptime {
    _ = ConstructorCallBinding;
    _ = ConstructorConstructBinding;
    _ = ConstructErrorBinding;
    _ = ConstructJSONBinding;
    _ = ConstructRedirectBinding;
    _ = ConstructRenderBinding;
    _ = ReleaseNativeResponseBinding;
}
