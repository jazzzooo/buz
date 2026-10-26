const bun = @import("bun");
const bindgen = bun.bindgen;

pub const DatabaseData = opaque {};
pub const StatementData = opaque {};
pub const ControlHandleData = opaque {};

const BindingModule = bindgen.Module("SQLiteNative");
const AdoptDatabaseSchema = BindingModule.nativeExport("adoptDatabase");
const AdoptStatementSchema = BindingModule.nativeExport("adoptStatement");
const DatabaseDataSchema = BindingModule.nativeExport("databaseData");
const StatementDataSchema = BindingModule.nativeExport("statementData");
const GetPrototypeSchema = BindingModule.nativeExport("getPrototype");
const SetPrototypeSchema = BindingModule.nativeExport("setPrototype");
const AdoptControlHandleSchema = BindingModule.nativeExport("adoptControlHandle");
const ControlHandleDataSchema = BindingModule.nativeExport("controlHandleData");
const InvokePointerCallbackSchema = BindingModule.nativeExport("invokePointerCallback");
const DatabaseSchema = BindingModule.class("Database");
const StatementSchema = BindingModule.class("Statement");
const ControlHandleSchema = BindingModule.class("ControlHandle");
const GetIdSchema = DatabaseSchema.member("id");
const GetControlKindSchema = ControlHandleSchema.member("kind");

pub const Database = struct {
    bindgen_state: bindgen.ClassState = .{},
    data: @FieldType(bindgen.Args(AdoptDatabaseSchema), "data"),
    identifier: i32,
    extra_memory: usize,

    pub const Binding = bindgen.Class(DatabaseSchema, Database);

    pub fn getId(this: *Database, _: bindgen.CallContext(GetIdSchema), _: bindgen.Args(GetIdSchema)) bun.JSError!i32 {
        return this.identifier;
    }

    pub fn destroy(this: *Database) void {
        this.data.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const Database, _: bindgen.MemoryUsageContext(.vm)) usize {
        return @sizeOf(Database) + this.extra_memory;
    }
};

pub const Statement = struct {
    bindgen_state: bindgen.ClassState = .{},
    data: @FieldType(bindgen.Args(AdoptStatementSchema), "data"),
    extra_memory: usize,

    pub const Binding = bindgen.Class(StatementSchema, Statement);

    pub fn destroy(this: *Statement) void {
        this.data.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const Statement, _: bindgen.MemoryUsageContext(.vm)) usize {
        return @sizeOf(Statement) + this.extra_memory;
    }
};

pub const ControlHandle = struct {
    bindgen_state: bindgen.ClassState = .{},
    data: @FieldType(bindgen.Args(AdoptControlHandleSchema), "data"),
    kind: @FieldType(bindgen.Args(AdoptControlHandleSchema), "kind"),
    extra_memory: usize,

    pub const Binding = bindgen.Class(ControlHandleSchema, ControlHandle);

    pub fn getKind(this: *ControlHandle, _: bindgen.CallContext(GetControlKindSchema), _: bindgen.Args(GetControlKindSchema)) bun.JSError!bindgen.Return(GetControlKindSchema) {
        return this.kind;
    }

    pub fn destroy(this: *ControlHandle) void {
        this.data.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const ControlHandle, _: bindgen.MemoryUsageContext(.vm)) usize {
        return @sizeOf(ControlHandle) + this.extra_memory;
    }
};

fn adoptControlHandle(context: bindgen.CallContext(AdoptControlHandleSchema), args: *bindgen.Args(AdoptControlHandleSchema)) bun.JSError!bindgen.Return(AdoptControlHandleSchema) {
    const handle = try bun.default_allocator.create(ControlHandle);
    handle.* = .{ .data = args.data.take(), .kind = args.kind, .extra_memory = args.memory };
    return ControlHandle.Binding.adoptResult(handle, context);
}

fn controlHandleData(_: bindgen.CallContext(ControlHandleDataSchema), args: bindgen.Args(ControlHandleDataSchema)) bun.JSError!*ControlHandleData {
    return args.handle.get(ControlHandle).data.get();
}

fn invokePointerCallback(_: bindgen.CallContext(InvokePointerCallbackSchema), args: bindgen.Args(InvokePointerCallbackSchema)) bun.JSError!bindgen.Return(InvokePointerCallbackSchema) {
    return args.callback.call(.{ .pointer = args.pointer });
}

fn adoptDatabase(context: bindgen.CallContext(AdoptDatabaseSchema), args: *bindgen.Args(AdoptDatabaseSchema)) bun.JSError!bindgen.Return(AdoptDatabaseSchema) {
    const database = try bun.default_allocator.create(Database);
    database.* = .{
        .data = args.data.take(),
        .identifier = args.identifier,
        .extra_memory = args.memory,
    };
    return Database.Binding.adoptResult(database, context);
}

fn adoptStatement(context: bindgen.CallContext(AdoptStatementSchema), args: *bindgen.Args(AdoptStatementSchema)) bun.JSError!bindgen.Return(AdoptStatementSchema) {
    const statement = try bun.default_allocator.create(Statement);
    statement.* = .{
        .data = args.data.take(),
        .extra_memory = args.memory,
    };
    return Statement.Binding.adoptResult(statement, context);
}

fn databaseData(args: bindgen.Args(DatabaseDataSchema)) *DatabaseData {
    return args.database.data.get();
}

fn statementData(_: bindgen.CallContext(StatementDataSchema), args: bindgen.Args(StatementDataSchema)) bun.JSError!*StatementData {
    return args.statement.get(Statement).data.get();
}

fn getPrototype(_: bindgen.CallContext(GetPrototypeSchema), args: bindgen.Args(GetPrototypeSchema)) bun.JSError!bindgen.Return(GetPrototypeSchema) {
    const value = try Statement.Binding.CachedSlot("userPrototype").view(args.statement);
    return if (value) |prototype| prototype.toResult() else null;
}

fn setPrototype(_: bindgen.CallContext(SetPrototypeSchema), args: bindgen.Args(SetPrototypeSchema)) bun.JSError!void {
    const Slot = Statement.Binding.CachedSlot("userPrototype");
    if (args.prototype) |prototype|
        Slot.setView(args.statement, prototype)
    else
        Slot.clearView(args.statement);
}

const AdoptDatabase = bindgen.Fn(AdoptDatabaseSchema, adoptDatabase);
const AdoptStatement = bindgen.Fn(AdoptStatementSchema, adoptStatement);
const DatabaseDataBinding = bindgen.Fn(DatabaseDataSchema, databaseData);
const StatementDataBinding = bindgen.Fn(StatementDataSchema, statementData);
const GetPrototype = bindgen.Fn(GetPrototypeSchema, getPrototype);
const SetPrototype = bindgen.Fn(SetPrototypeSchema, setPrototype);
const AdoptControlHandle = bindgen.Fn(AdoptControlHandleSchema, adoptControlHandle);
const ControlHandleDataBinding = bindgen.Fn(ControlHandleDataSchema, controlHandleData);
const InvokePointerCallback = bindgen.Fn(InvokePointerCallbackSchema, invokePointerCallback);

comptime {
    _ = Database.Binding;
    _ = Statement.Binding;
    _ = ControlHandle.Binding;
    _ = AdoptDatabase;
    _ = AdoptStatement;
    _ = DatabaseDataBinding;
    _ = StatementDataBinding;
    _ = GetPrototype;
    _ = SetPrototype;
    _ = AdoptControlHandle;
    _ = ControlHandleDataBinding;
    _ = InvokePointerCallback;
}
