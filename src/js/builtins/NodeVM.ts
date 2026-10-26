export function runInNewContext(contextObject, options) {
  const { validateString, validateObject, validateBoolean } = require("internal/validators");
  let contextOptions;
  if (options) {
    const name = options.contextName;
    const origin = options.contextOrigin;
    const microtaskMode = options.microtaskMode;
    if (name !== undefined) validateString(name, "options.contextName");
    if (origin !== undefined) validateString(origin, "options.contextOrigin");

    const contextCodeGeneration = options.contextCodeGeneration;
    let codeGeneration;
    if (contextCodeGeneration !== undefined) {
      validateObject(contextCodeGeneration, "options.contextCodeGeneration");
      const { strings, wasm } = contextCodeGeneration;
      if (strings !== undefined) validateBoolean(strings, "options.contextCodeGeneration.strings");
      if (wasm !== undefined) validateBoolean(wasm, "options.contextCodeGeneration.wasm");
      codeGeneration = { strings, wasm };
    }
    if (microtaskMode !== undefined) validateString(microtaskMode, "options.microtaskMode");
    contextOptions = { name, origin, codeGeneration, microtaskMode };
  }
  const context = $bindgenFn("NodeVM.schema.zig", "createContext")(contextObject, contextOptions);
  const runInContext = this.runInContext;
  if (typeof runInContext !== "function") $throwTypeError("this.runInContext is not a function");
  return runInContext.$call(this, context, options);
}
