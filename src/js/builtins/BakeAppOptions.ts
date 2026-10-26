export function createFromModuleDefault(moduleDefault) {
  if (!$isObject(moduleDefault)) {
    throw new TypeError(`Your config file's default export must be an object.

Example:
  export default {
    app: {
      framework: "react",
    }
  }

Learn more at https://bun.com/docs/ssg`);
  }

  if (!("app" in moduleDefault)) {
    throw new TypeError(`Your config file's default export must contain an "app" property.

Example:
  export default {
    app: {
      framework: "react",
    }
  }

Learn more at https://bun.com/docs/ssg`);
  }

  return $bindgenFn("BakeAppOptions.schema.zig", "createNative")(moduleDefault.app);
}
