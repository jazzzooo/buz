const bun = @import("bun");
const bindgen = bun.bindgen;
const jsc = bun.jsc;

const ModuleRunMainBindings = bindgen.Module("module_run_main");
const BunObjectBindings = bindgen.Module("BunObject");
const MainGetSchema = BunObjectBindings.function("mainGet");
const MainSetSchema = BunObjectBindings.function("mainSet");
const SetOverrideSchema = ModuleRunMainBindings.nativeExport("setOverrideModuleRunMain");
const SetOverridePromiseSchema = ModuleRunMainBindings.nativeExport("setOverrideModuleRunMainPromise");
const LogUnhandledExceptionSchema = ModuleRunMainBindings.nativeExport("logUnhandledException");
const SpecifierIsEvalEntryPointSchema = ModuleRunMainBindings.nativeExport("specifierIsEvalEntryPoint");
const SetEntryPointEvalResultESMSchema = ModuleRunMainBindings.nativeExport("setEntryPointEvalResultESM");
const SetEntryPointEvalResultCJSSchema = ModuleRunMainBindings.nativeExport("setEntryPointEvalResultCJS");

fn mainEntryResult(globalThis: *jsc.JSGlobalObject, context: anytype) bun.JSError!bindgen.AnyResult {
    const vm = globalThis.bunVM();
    if (vm.overridden_main.toResult(context)) |overridden| return overridden;

    var value = resolve_path: {
        if (vm.main_resolved_path.isEmpty()) {
            if (bun.strings.hasSuffixComptime(vm.main, "[eval]") or
                bun.strings.hasSuffixComptime(vm.main, "[stdin]"))
            {
                break :resolve_path try bindgen.DOMString.fromUTF8(vm.main);
            }

            const fd = bun.sys.openatA(
                if (comptime bun.Environment.isWindows) bun.invalid_fd else bun.FD.cwd(),
                vm.main,
                if (comptime bun.Environment.isLinux) bun.O.PATH else bun.O.RDONLY,
                0,
            ).unwrap() catch break :resolve_path try bindgen.DOMString.fromUTF8(vm.main);
            defer fd.close();

            if (comptime bun.Environment.isWindows) {
                var path: bun.WPathBuffer = undefined;
                const resolved = bun.getFdPathW(fd, &path) catch break :resolve_path try bindgen.DOMString.fromUTF8(vm.main);
                var resolved_name = try bindgen.DOMString.fromUTF16(resolved);
                vm.main_resolved_path = resolved_name.takeBunString();
            } else {
                var path: bun.PathBuffer = undefined;
                const resolved = bun.getFdPath(fd, &path) catch break :resolve_path try bindgen.DOMString.fromUTF8(vm.main);
                vm.main_resolved_path = if (bun.api.StringEngine.tryCreateAtomASCII(resolved)) |atom|
                    atom
                else resolved_name: {
                    var name = try bindgen.DOMString.fromUTF8(resolved);
                    break :resolved_name name.takeBunString();
                };
            }
        }
        break :resolve_path try bindgen.DOMString.fromBunString(vm.main_resolved_path.dupeRef());
    };
    defer value.deinit();
    const result = try context.engineIn("js_strings", "stringToJS").call(.{ .value = value.operand() });
    return result.asAny(context);
}

pub const MainEntry = struct {
    pub fn isBunMain(main_value: bindgen.DOMStringView) bool {
        return main_value.eqlUTF8(jsc.VirtualMachine.get().main);
    }

    pub fn get(context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
        return mainEntryResult(context.viewToken().globalObject(), context);
    }

    pub fn set(args: bindgen.Args(MainSetSchema)) bun.JSError!bool {
        var root = try args.value.toRoot();
        defer root.deinit();
        jsc.VirtualMachine.get().overridden_main.setRoot(&root);
        return true;
    }
};

pub fn setOverrideModuleRunMain(args: bindgen.Args(SetOverrideSchema)) void {
    jsc.VirtualMachine.get().setOverrideModuleRunMain(args.isPatched);
}

pub fn setOverrideModuleRunMainPromise(context: anytype, args: bindgen.Args(SetOverridePromiseSchema)) bun.JSError!void {
    const global = context.viewToken().globalObject();
    try global.bunVM().setOverrideModuleRunMainPromise(
        args.promise,
    );
}

pub fn logUnhandledException(context: anytype, args: bindgen.Args(LogUnhandledExceptionSchema)) void {
    context.runErrorHandler(args.exception.operand(context).asAny());
}

pub fn specifierIsEvalEntryPoint(context: anytype, args: bindgen.Args(SpecifierIsEvalEntryPointSchema)) bun.JSError!bool {
    const source = context.viewToken().globalObject().bunVM().module_loader.eval_source orelse return false;
    // Coercion can replace and release the eval source.
    const path = try bun.default_allocator.dupe(u8, source.path.text);
    defer bun.default_allocator.free(path);
    const converted = try args.specifier.convert(context);
    return converted.value.eqlUTF8(path);
}

pub fn setEntryPointEvalResultESM(context: anytype, args: bindgen.Args(SetEntryPointEvalResultESMSchema)) bun.JSError!void {
    const vm = context.viewToken().globalObject().bunVM();
    if (!vm.entry_point_result.cjs_set_value) {
        var root = try args.result.toRoot();
        defer root.deinit();
        vm.entry_point_result.value.setRoot(&root);
    }
}

pub fn setEntryPointEvalResultCJS(context: anytype, args: bindgen.Args(SetEntryPointEvalResultCJSSchema)) bun.JSError!void {
    const vm = context.viewToken().globalObject().bunVM();
    if (!vm.entry_point_result.value.has()) {
        var root = try args.result.toRoot();
        defer root.deinit();
        vm.entry_point_result.value.setRoot(&root);
        vm.entry_point_result.cjs_set_value = true;
    }
}
