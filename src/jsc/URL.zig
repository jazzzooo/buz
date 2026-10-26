pub const URL = struct {
    handle: URLHandle,

    fn toBindingString(value: String) bun.OOM!bun.bindgen.ThreadSafeDOMString {
        return bun.bindgen.ThreadSafeDOMString.fromBunString(value.dupeRef());
    }

    fn takeBindingString(value: bun.bindgen.ThreadSafeDOMString) String {
        var owned = value;
        return owned.takeBunString();
    }

    fn takeOptionalBindingString(value: ?bun.bindgen.ThreadSafeDOMString) String {
        var optional = value;
        if (optional) |*owned| return owned.takeBunString();
        return .dead;
    }

    fn StringGetter(comptime operation: []const u8) type {
        return struct {
            pub fn call(url: *const URL) bun.OOM!String {
                return takeBindingString(try bun.bindgen.Engine(URLBindings.engineShim(operation)).call(.{ .url = &url.handle }));
            }
        };
    }

    /// Includes the leading '#'.
    pub const hash = StringGetter("urlHash").call;

    /// Exactly the same as hash, excluding the leading '#'.
    pub const fragmentIdentifier = StringGetter("urlFragmentIdentifier").call;

    pub fn hrefFromString(str: String) bun.OOM!String {
        var input = try toBindingString(str);
        defer input.deinit();
        return takeOptionalBindingString(try bun.bindgen.Engine(URLHrefFromStringSchema).call(.{ .input = input.operand() }));
    }

    pub fn hrefFromDOMString(str: *const bun.bindgen.DOMString) bun.OOM!bun.bindgen.DOMString {
        var owned_input = str.clone();
        defer owned_input.deinit();
        var input = try owned_input.toThreadSafe();
        defer input.deinit();
        var output = (try bun.bindgen.Engine(URLHrefFromStringSchema).call(.{ .input = input.operand() })) orelse return .empty();
        return bun.bindgen.DOMString.fromBunString(output.takeBunString());
    }

    pub fn join(base: String, relative: String) bun.OOM!String {
        var bound_base = try toBindingString(base);
        defer bound_base.deinit();
        var bound_relative = try toBindingString(relative);
        defer bound_relative.deinit();
        return takeOptionalBindingString(try bun.bindgen.Engine(URLJoinSchema).call(.{
            .base = bound_base.operand(),
            .relative = bound_relative.operand(),
        }));
    }

    pub fn fileURLFromString(str: String) bun.OOM!String {
        var input = try toBindingString(str);
        defer input.deinit();
        return takeBindingString(try bun.bindgen.Engine(URLFileURLFromStringSchema).call(.{ .input = input.operand() }));
    }

    pub fn pathFromFileURL(str: String) bun.OOM!?String {
        var input = try toBindingString(str);
        defer input.deinit();
        const result = (try bun.bindgen.Engine(URLPathFromFileURLSchema).call(.{ .input = input.operand() })) orelse return null;
        return takeBindingString(result);
    }

    pub fn fromUTF8(input: []const u8) bun.OOM!?URL {
        var input_string = try bun.bindgen.ThreadSafeDOMString.fromUTF8(input);
        defer input_string.deinit();
        const handle = (try bun.bindgen.Engine(URLFromStringSchema).call(.{ .input = input_string.operand() })) orelse return null;
        return .{ .handle = handle };
    }

    pub fn fromString(str: String) bun.OOM!?URL {
        var input = try toBindingString(str);
        defer input.deinit();
        const handle = (try bun.bindgen.Engine(URLFromStringSchema).call(.{ .input = input.operand() })) orelse return null;
        return .{ .handle = handle };
    }

    pub const protocol = StringGetter("urlProtocol").call;

    pub const href = StringGetter("urlHref").call;

    pub const username = StringGetter("urlUsername").call;

    pub const password = StringGetter("urlPassword").call;

    pub const search = StringGetter("urlSearch").call;

    /// Returns the host WITHOUT the port.
    ///
    /// Note that this does NOT match JS behavior, which returns the host with the port. See
    /// `hostname` for the JS equivalent of `host`.
    ///
    /// ```
    /// URL("http://example.com:8080").host() => "example.com"
    /// ```
    pub const host = StringGetter("urlHost").call;

    /// Returns the host WITH the port.
    ///
    /// Note that this does NOT match JS behavior which returns the host without the port. See
    /// `host` for the JS equivalent of `hostname`.
    ///
    /// ```
    /// URL("http://example.com:8080").hostname() => "example.com:8080"
    /// ```
    pub const hostname = StringGetter("urlHostname").call;

    pub fn port(url: *const URL) ?u16 {
        return bun.bindgen.Engine(URLPortSchema).call(.{ .url = &url.handle });
    }

    pub fn deinit(url: *URL) void {
        url.handle.deinit();
    }

    pub const pathname = StringGetter("urlPathname").call;

    pub fn originFromUTF8(bytes: []const u8) bun.OOM!?bun.bindgen.ThreadSafeDOMString {
        var input = try bun.bindgen.ThreadSafeDOMString.fromUTF8(bytes);
        defer input.deinit();
        return bun.bindgen.Engine(URLOriginFromStringSchema).call(.{ .input = input.operand() });
    }
};

const bun = @import("bun");
const String = bun.String;

const URLBindings = bun.bindgen.Module("urls");
const URLFromStringSchema = URLBindings.engineShim("urlFromString");
const URLHrefFromStringSchema = URLBindings.engineShim("urlHrefFromString");
const URLFileURLFromStringSchema = URLBindings.engineShim("urlFileURLFromString");
const URLJoinSchema = URLBindings.engineShim("urlJoin");
const URLPathFromFileURLSchema = URLBindings.engineShim("urlPathFromFileURL");
const URLPortSchema = URLBindings.engineShim("urlPort");
const URLOriginFromStringSchema = URLBindings.engineShim("urlOriginFromString");
const URLHandle = @typeInfo(bun.bindgen.Return(URLFromStringSchema)).optional.child;
