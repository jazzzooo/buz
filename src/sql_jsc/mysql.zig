pub fn createBinding(globalObject: *jsc.JSGlobalObject) JSValue {
    const binding = jsc.JSObject.createEmptyWithNullPrototype(globalObject);
    binding.putDirect(globalObject, ZigString.static("MySQLConnection"), MySQLConnection.js.getConstructor(globalObject));
    binding.putDirect(globalObject, ZigString.static("init"), jsc.JSFunction.create(globalObject, "init", MySQLContext.init, 0, .{}).toJS());
    binding.putDirect(
        globalObject,
        ZigString.static("createQuery"),
        jsc.JSFunction.create(globalObject, "createQuery", MySQLQuery.createInstance, 6, .{}).toJS(),
    );

    binding.putDirect(
        globalObject,
        ZigString.static("createConnection"),
        jsc.JSFunction.create(globalObject, "createConnection", MySQLConnection.createInstance, 2, .{}).toJS(),
    );

    return binding.toJS();
}

pub const MySQLConnection = @import("./mysql/JSMySQLConnection.zig");
pub const MySQLContext = @import("./mysql/MySQLContext.zig");
pub const MySQLQuery = @import("./mysql/JSMySQLQuery.zig");

const bun = @import("bun");

const jsc = bun.jsc;
const JSValue = jsc.JSValue;
const ZigString = jsc.ZigString;
