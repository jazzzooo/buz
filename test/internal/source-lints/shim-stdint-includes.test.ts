import { Glob } from "bun";
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

// Native shim headers are consumed by C/C++ and Zig's C translator, so their
// fixed-width integer types must not depend on transitive SDK includes.
test("native shim headers that use fixed-width integer types include a standard integer header", () => {
  const bindingsDir = path.resolve(import.meta.dir, "..", "..", "..", "src");
  const shims = [...new Glob("*_sys/Bun*.h").scanSync({ cwd: bindingsDir })];
  expect(shims.length).toBeGreaterThan(0);

  const fixedWidthType = /\b(?:u?int(?:8|16|32|64)_t|intptr_t|uintptr_t)\b/;
  const stdintInclude = /#include\s*<(?:cstdint|stdint\.h)>/;

  const violations = shims
    .filter(name => {
      const source = readFileSync(path.join(bindingsDir, name), "utf8");
      return fixedWidthType.test(source) && !stdintInclude.test(source);
    })
    .map(name => `src/${name} uses fixed-width integer types but does not include <stdint.h> or <cstdint>`);

  expect(violations).toEqual([]);
});
