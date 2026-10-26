pub const FormDataObject = struct {
    pub const Binding = bun.bindgen.Class(FormSchema, FormDataObject);
    pub const fromMultipartData = @import("../runtime/webcore/FormDataEngine.zig").fromMultipartData;

    bindgen_state: bun.bindgen.ClassState = .{},
    resource: DOMFormData.Owner,

    pub fn create(resource: DOMFormData.Owner) bun.OOM!*FormDataObject {
        var owned = resource;
        errdefer owned.deinit();
        const object = try bun.default_allocator.create(FormDataObject);
        object.* = .{ .resource = owned };
        return object;
    }

    pub fn construct(context: bun.bindgen.CallContext(ConstructorSchema), _: bun.bindgen.Args(ConstructorSchema)) bun.JSError!*FormDataObject {
        return create(try context.engineIn("WebCoreFormData", "formDataCreate").call(.{}));
    }

    pub fn destroy(this: *FormDataObject) void {
        this.resource.deinit();
        bun.default_allocator.destroy(this);
    }

    pub fn memoryUsage(this: *const FormDataObject, _: bun.bindgen.MemoryUsageContext(.vm)) usize {
        return @sizeOf(FormDataObject) +| bun.bindgen.Engine(MemoryCostSchema).call(.{ .form = this.resource.get() });
    }

    pub fn append(this: *FormDataObject, context: bun.bindgen.CallContext(AppendSchema), args: bun.bindgen.Args(AppendSchema)) bun.JSError!void {
        switch (args) {
            .string => |input| try context.engineIn("WebCoreFormData", "formDataAppendString").callForwarded(input, .{ .form = this.resource.get() }),
            .blob => |input| try context.engineIn("WebCoreFormData", "formDataAppendBlob").callForwarded(input, .{ .form = this.resource.get(), .wrapper = input.bindingThis.value().operand(context), .original = input.value.value().operand(context) }),
        }
    }

    pub fn delete(this: *FormDataObject, context: bun.bindgen.CallContext(DeleteSchema), args: bun.bindgen.Args(DeleteSchema)) bun.JSError!void {
        try context.engineIn("WebCoreFormData", "formDataDelete").callForwarded(args, .{ .form = this.resource.get(), .wrapper = args.bindingThis.value().operand(context) });
    }

    pub fn get(this: *FormDataObject, context: bun.bindgen.CallContext(GetSchema), args: bun.bindgen.Args(GetSchema)) bun.JSError!bun.bindgen.Return(GetSchema) {
        const value = (try context.engineIn("WebCoreFormData", "formDataGet").callForwarded(args, .{ .form = this.resource.get(), .wrapper = args.bindingThis.value().operand(context) })) orelse return null;
        return try retainEntryValue(value);
    }

    pub fn getAll(this: *FormDataObject, context: bun.bindgen.CallContext(GetAllSchema), args: bun.bindgen.Args(GetAllSchema)) bun.JSError!bun.bindgen.Return(GetAllSchema) {
        return (try context.engineIn("WebCoreFormData", "formDataGetAll").callForwarded(args, .{ .form = this.resource.get(), .wrapper = args.bindingThis.value().operand(context) })).take();
    }

    pub fn has(this: *FormDataObject, context: bun.bindgen.CallContext(HasSchema), args: bun.bindgen.Args(HasSchema)) bun.JSError!bool {
        return context.engineIn("WebCoreFormData", "formDataHas").callForwarded(args, .{ .form = this.resource.get() });
    }

    pub fn set(this: *FormDataObject, context: bun.bindgen.CallContext(SetSchema), args: bun.bindgen.Args(SetSchema)) bun.JSError!void {
        switch (args) {
            .string => |input| try context.engineIn("WebCoreFormData", "formDataSetString").callForwarded(input, .{ .form = this.resource.get(), .wrapper = input.bindingThis.value().operand(context) }),
            .blob => |input| try context.engineIn("WebCoreFormData", "formDataSetBlob").callForwarded(input, .{ .form = this.resource.get(), .wrapper = input.bindingThis.value().operand(context), .original = input.value.value().operand(context) }),
        }
    }

    fn JSONMethod(comptime FunctionSchema: type) type {
        return struct {
            pub fn call(this: *FormDataObject, context: bun.bindgen.CallContext(FunctionSchema), args: bun.bindgen.Args(FunctionSchema)) bun.JSError!bun.bindgen.Return(FunctionSchema) {
                return (try context.engineIn("WebCoreFormData", "formDataJSON").call(.{ .form = this.resource.get(), .wrapper = args.bindingThis.value().operand(context) })).take();
            }
        };
    }

    pub const toJSON = JSONMethod(FormSchema.member("toJSON")).call;

    pub const inspectCustom = JSONMethod(FormSchema.member("inspectCustom")).call;

    pub fn getLength(this: *FormDataObject, context: bun.bindgen.CallContext(LengthSchema), _: bun.bindgen.Args(LengthSchema)) bun.JSError!usize {
        return context.engineIn("WebCoreFormData", "formDataCount").call(.{ .form = this.resource.get() });
    }

    fn createIterator(this: *FormDataObject, context: anytype, receiver: bun.bindgen.ClassRefView(FormSchema), kind: Iterator.Kind) bun.JSError!bun.bindgen.ClassRef(IteratorSchema) {
        var handle = try bun.bindgen.Engine(IteratorCreateSchema).call(.{ .form = this.resource.get() });
        defer handle.deinit();
        const iterator = try bun.default_allocator.create(Iterator);
        iterator.* = .{ .handle = handle.take(), .kind = kind };
        var result = try IteratorClass.adoptResult(iterator, context);
        errdefer result.deinit();
        var form = try receiver.toOwned();
        defer form.deinit();
        IteratorClass.CachedClassRefSlot("form").setOnOwned(&result, &form);
        return result;
    }

    pub fn entries(this: *FormDataObject, context: bun.bindgen.CallContext(EntriesSchema), args: bun.bindgen.Args(EntriesSchema)) bun.JSError!bun.bindgen.Return(EntriesSchema) {
        return this.createIterator(context, args.bindingThis, .entries);
    }

    pub fn keys(this: *FormDataObject, context: bun.bindgen.CallContext(KeysSchema), args: bun.bindgen.Args(KeysSchema)) bun.JSError!bun.bindgen.Return(KeysSchema) {
        return this.createIterator(context, args.bindingThis, .keys);
    }

    pub fn values(this: *FormDataObject, context: bun.bindgen.CallContext(ValuesSchema), args: bun.bindgen.Args(ValuesSchema)) bun.JSError!bun.bindgen.Return(ValuesSchema) {
        return this.createIterator(context, args.bindingThis, .values);
    }

    pub fn bindForEach(this: *FormDataObject, context: bun.bindgen.CallContext(ForEachSchema), args: bun.bindgen.Args(ForEachSchema)) bun.JSError!void {
        var receiver = try args.bindingThis.toOwned();
        defer receiver.deinit();
        var iterator = try bun.bindgen.Engine(IteratorCreateSchema).call(.{ .form = this.resource.get() });
        defer iterator.deinit();
        while (try context.engineIn("WebCoreFormData", "formDataIteratorEntry").call(.{ .iterator = &iterator, .wrapper = args.bindingThis.value().operand(context) })) |item| {
            var owned_entry: bun.bindgen.Return(IteratorEntrySchema) = item;
            defer bun.bindgen.deinitReturn(IteratorEntrySchema, &owned_entry);
            const entry = &owned_entry.?;
            const callback_args: bun.bindgen.Args(@TypeOf(args.callback).SemanticType) = .{
                .key = entry.key.operand(),
                .value = switch (entry.value) {
                    .string => |*value| .{ .string = value.operand() },
                    .blob => |*value| .{ .blob = value.operand(context) },
                },
                .formData = receiver.operand(context),
                .bindingThis = if (args.thisArg) |value| value.operand(context) else null,
            };
            try args.callback.call(callback_args);
        }
    }
};

pub const DOMFormData = opaque {
    pub const Owner = bun.bindgen.Return(RetainSchema);

    pub fn retain(this: *DOMFormData) Owner {
        return bun.bindgen.Engine(RetainSchema).call(.{ .form = this });
    }

    pub const FormDataEntry = union(enum) {
        string: bun.TextView,
        file: struct {
            blob: *jsc.WebCore.Blob,
            filename: bun.TextView,
        },
    };
    pub fn forEach(
        this: *DOMFormData,
        comptime Context: type,
        ctx: *Context,
        comptime callback_wrapper: *const fn (ctx: *Context, name: bun.TextView, value: FormDataEntry) bun.JSError!void,
    ) bun.JSError!void {
        var index: usize = 0;
        while (bun.bindgen.Engine(DOMFormDataEntrySchema).call(.{
            .form = this,
            .index = index,
        })) |entry| : (index += 1) {
            var owned_entry: bun.bindgen.Return(DOMFormDataEntrySchema) = entry;
            defer bun.bindgen.deinitReturn(DOMFormDataEntrySchema, &owned_entry);
            const result = &owned_entry.?;

            const value: FormDataEntry = switch (result.value) {
                .string => |*string| .{ .string = string.unsafePtr("owned_entry retains the string until the form-data callback returns").textView() },
                .file => |*file| .{ .file = .{
                    .blob = @ptrCast(@alignCast(file.blob)),
                    .filename = file.filename.unsafePtr("owned_entry retains the string until the form-data callback returns").textView(),
                } },
            };
            try callback_wrapper(ctx, result.name.unsafePtr("owned_entry retains the string until the form-data callback returns").textView(), value);
        }
    }
};

const Iterator = struct {
    const Kind = bun.bindgen.EngineArgumentType(IteratorNextSchema, "kind");

    bindgen_state: bun.bindgen.ClassState = .{},
    handle: bun.bindgen.Return(IteratorCreateSchema),
    kind: Kind,
    done: bool = false,

    pub fn destroy(this: *Iterator) void {
        this.handle.deinit();
        bun.destroy(this);
    }

    pub fn next(this: *Iterator, context: bun.bindgen.CallContext(NextSchema), args: bun.bindgen.Args(NextSchema)) bun.JSError!bun.bindgen.Return(NextSchema) {
        if (this.done) return .{ .value = null, .done = true };
        var receiver = try args.bindingThis.toOwned();
        defer receiver.deinit();
        var form = (try IteratorClass.CachedClassRefSlot("form").getOwned(&receiver)) orelse @panic("FormData iterator lost its target");
        defer form.deinit();
        const result = try context.engineIn("WebCoreFormData", "formDataIteratorNext").call(.{ .iterator = &this.handle, .wrapper = (try form.view(context)).value().operand(context), .kind = this.kind });
        if (result.done) {
            this.done = true;
            this.handle.deinit();
            IteratorClass.CachedSlotInvalidator("form").clearView(args.bindingThis);
        }
        return .{
            .done = result.done,
            .value = if (result.value) |value| switch (value) {
                .entry => |entry| .{ .entry = entry.take() },
                .value => |entry| .{ .value = try retainEntryValue(entry) },
            } else null,
        };
    }
};

fn retainEntryValue(value: @typeInfo(bun.bindgen.Return(FormDataGetEngineSchema)).optional.child) bun.JSError!@typeInfo(bun.bindgen.Return(GetSchema)).optional.child {
    return switch (value) {
        .string => |string| .{ .string = string },
        .blob => |blob| .{ .blob = try blob.toOwned() },
    };
}

const bun = @import("bun");

const jsc = bun.jsc;

const DOMFormDataBindings = bun.bindgen.Module("dom_form_data");
const DOMFormDataEntrySchema = DOMFormDataBindings.engineShim("domFormDataEntry");
const RetainSchema = DOMFormDataBindings.engineShim("domFormDataRetain");
const MemoryCostSchema = DOMFormDataBindings.engineShim("domFormDataMemoryCost");
const RetainFromWrapperSchema = DOMFormDataBindings.nativeExport("formDataRetainFromWrapper");
const IteratorCreateSchema = DOMFormDataBindings.engineShim("domFormDataIteratorCreate");
const WebCoreBindings = bun.bindgen.Module("WebCoreFormData");
const FormSchema = WebCoreBindings.class("FormData");
const ConstructorSchema = FormSchema.constructor();
const AppendSchema = FormSchema.member("append");
const DeleteSchema = FormSchema.member("delete");
const GetSchema = FormSchema.member("get");
const FormDataGetEngineSchema = WebCoreBindings.engineShim("formDataGet");
const IteratorEntrySchema = WebCoreBindings.engineShim("formDataIteratorEntry");
const GetAllSchema = FormSchema.member("getAll");
const HasSchema = FormSchema.member("has");
const SetSchema = FormSchema.member("set");
const LengthSchema = FormSchema.member("length");
const EntriesSchema = FormSchema.member("entries");
const KeysSchema = FormSchema.member("keys");
const ValuesSchema = FormSchema.member("values");
const ForEachSchema = FormSchema.member("forEach");
const IteratorSchema = WebCoreBindings.class("FormDataIterator");
const NextSchema = IteratorSchema.member("next");
const IteratorNextSchema = WebCoreBindings.engineShim("formDataIteratorNext");
const IteratorClass = bun.bindgen.Class(IteratorSchema, Iterator);

fn retainFromWrapper(_: bun.bindgen.CallContext(RetainFromWrapperSchema), args: bun.bindgen.Args(RetainFromWrapperSchema)) bun.JSError!bun.bindgen.Return(RetainFromWrapperSchema) {
    return args.value.get(FormDataObject).resource.get().retain();
}

comptime {
    _ = FormDataObject.Binding;
    _ = IteratorClass;
    _ = bun.bindgen.Fn(RetainFromWrapperSchema, retainFromWrapper);
}
