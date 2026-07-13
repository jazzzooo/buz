// Every expect matcher must bump the test runner's expect-call counter so
// `expect.assertions(n)` / `expect.hasAssertions()` work.
import { Glob } from "bun";
import { expect, test } from "bun:test";
import { readFileSync } from "fs";
import { basename, join } from "path";

const MATCHER_DIR = join(import.meta.dir, "../../src/test_runner/expect");

const satisfying = ["incrementExpectCallCounter"];

// Matchers that delegate to another matcher's implementation.
const excluded = new Set(["toHaveReturnedTimes.zig"]);

test("every expect matcher increments the expect-call counter", () => {
  const glob = new Glob("*.zig");
  const files = [...glob.scanSync({ cwd: MATCHER_DIR, absolute: true })].sort();
  expect(files.length).toBeGreaterThan(40);

  const missing: string[] = [];
  for (const file of files) {
    if (excluded.has(basename(file))) continue;
    const src = readFileSync(file, "utf8");
    if (!satisfying.some(token => src.includes(token))) {
      missing.push(basename(file));
    }
  }

  expect(missing).toEqual([]);
});
