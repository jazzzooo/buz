const Key = struct {
    service: bindgen.ThreadSafeDOMStringView,
    name: bindgen.ThreadSafeDOMStringView,

    fn positional(args: anytype) ?Key {
        if (args.input != .string) return null;
        const name = args.name orelse return null;
        if (name != .string) return null;
        return .{ .service = args.input.string, .name = name.string };
    }

    fn fromArguments(comptime Schema: type, context: bindgen.CallContext(Schema), args: anytype) bindgen.CallError(Schema)!Key {
        if (positional(args)) |key| return key;
        const options = args.options orelse return context.fail(.invalid_options, {});
        return fromOptions(Schema, context, (try options.convert(context)).value);
    }

    fn fromOptions(comptime Schema: type, context: bindgen.CallContext(Schema), options: anytype) bindgen.CallError(Schema)!Key {
        return .{
            .service = (try options.service.convert(context)).value,
            .name = (try options.name.convert(context)).value,
        };
    }
};

fn get(
    context: bindgen.CallContext(GetSchema),
    args: bindgen.Args(GetSchema),
) bindgen.CallError(GetSchema)!void {
    const key = try Key.fromArguments(GetSchema, context, args);
    return start(GetSchema, .get, context, key, null, false);
}

fn set(
    context: bindgen.CallContext(SetSchema),
    args: bindgen.Args(SetSchema),
) bindgen.CallError(SetSchema)!void {
    if (Key.positional(args)) |key| {
        if (args.value) |value| {
            if (value == .string) return start(SetSchema, .set, context, key, value.string, false);
        }
    }
    const lazy_options = args.options orelse return context.fail(.invalid_options, {});
    const options = (try lazy_options.convert(context)).value;
    const key = try Key.fromOptions(SetSchema, context, options);
    const value = (try options.value.convert(context)).value orelse return context.fail(.missing_value, {});
    const allow_unrestricted_access = (try options.allow_unrestricted_access.convert(context)).value;
    return start(SetSchema, .set, context, key, value, allow_unrestricted_access);
}

fn delete(
    context: bindgen.CallContext(DeleteSchema),
    args: bindgen.Args(DeleteSchema),
) bindgen.CallError(DeleteSchema)!void {
    const key = try Key.fromArguments(DeleteSchema, context, args);
    return start(DeleteSchema, .delete_op, context, key, null, false);
}

fn start(
    comptime Schema: type,
    comptime operation: Operation,
    context: bindgen.CallContext(Schema),
    key: Key,
    password: ?bindgen.ThreadSafeDOMStringView,
    allow_unrestricted_access: bool,
) bindgen.CallError(Schema)!void {
    if (key.service.length() == 0 or key.name.length() == 0)
        return context.fail(.invalid_key, {});

    var service = try key.service.toOwned();
    defer service.deinit();
    var name = try key.name.toOwned();
    defer name.deinit();
    var owned_password: ?bindgen.ThreadSafeDOMString = if (password) |value| try value.toOwned() else null;
    defer if (owned_password) |*value| value.deinit();

    const options = bindgen.Engine(CreateSchema).call(.{
        .operation = operation,
        .service = service.operand(),
        .name = name.operand(),
        .password = if (owned_password) |text| text.operand() else null,
        .allow_unrestricted_access = allow_unrestricted_access,
    });
    var completion = context.completion();
    const job = bun.new(Job(Schema, operation), .{
        .completion = completion.take(),
        .options = options,
    });
    job.schedule(bun.current_runtime.backgroundTasks());
}

fn Job(comptime Schema: type, comptime operation: Operation) type {
    return struct {
        completion: bindgen.OwnedCompletion(Schema),
        options: OwnedOptions,
        task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

        const Self = @This();

        pub fn schedule(this: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
            bun.BackgroundWork.schedule(background_tasks, &this.task) catch {
                this.completion.fail(.not_available, {});
                this.deinit();
            };
        }

        fn run(task: *bun.BackgroundTaskGroup.Task) void {
            const this: *Self = @fieldParentPtr("task", task);
            defer this.deinit();

            bindgen.Engine(RunTaskSchema).call(.{ .options = &this.options });
            var result = bindgen.Engine(TakeResultSchema).call(.{ .options = &this.options }) catch {
                this.completion.outOfMemory();
                return;
            };
            defer bindgen.deinitReturn(TakeResultSchema, &result);
            this.finish(&result);
        }

        fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
            const this: *Self = @fieldParentPtr("task", task);
            this.completion.release();
            this.deinit();
        }

        fn finish(this: *Self, result: *Result) void {
            switch (result.error_kind) {
                .none => switch (operation) {
                    .get => if (result.password) |*password|
                        this.completion.resolve(password.take())
                    else
                        this.completion.resolve(null),
                    .set => this.completion.resolve({}),
                    .delete_op => this.completion.resolve(result.deleted),
                },
                .not_found => switch (operation) {
                    .get => this.completion.resolve(null),
                    .delete_op => this.completion.resolve(false),
                    .set => this.completion.fail(.not_found, result.message.take()),
                },
                .access_denied => switch (result.platform_code) {
                    -25308 => this.completion.fail(.interaction_not_allowed, result.message.take()),
                    -25293 => this.completion.fail(.authentication_failed, result.message.take()),
                    -25315 => this.completion.fail(.interaction_required, result.message.take()),
                    -128 => this.completion.fail(.user_canceled, result.message.take()),
                    else => this.completion.fail(.access_denied, result.message.take()),
                },
                .platform_error => this.completion.fail(.platform_error, result.message.take()),
            }
        }

        fn deinit(this: *Self) void {
            this.options.deinit();
            bun.destroy(this);
        }
    };
}

const bun = @import("bun");
const bindgen = bun.bindgen;
const SecretsBindings = bindgen.Module("Secrets");
const GetSchema = SecretsBindings.function("get");
const SetSchema = SecretsBindings.function("set");
const DeleteSchema = SecretsBindings.function("delete");
const GetBinding = bindgen.Fn(GetSchema, get);
const SetBinding = bindgen.Fn(SetSchema, set);
const DeleteBinding = bindgen.Fn(DeleteSchema, delete);

comptime {
    _ = GetBinding;
    _ = SetBinding;
    _ = DeleteBinding;
}

const EngineApiBindings = bun.bindgen.Module("secrets_engine");
const CreateSchema = EngineApiBindings.engineShim("secretsJobCreate");
const RunTaskSchema = EngineApiBindings.engineShim("secretsJobRunTask");
const TakeResultSchema = EngineApiBindings.engineShim("secretsJobTakeResult");
const Operation = @FieldType(bindgen.Args(CreateSchema), "operation");
const OwnedOptions = bindgen.Return(CreateSchema);
const Result = bindgen.Return(TakeResultSchema);
