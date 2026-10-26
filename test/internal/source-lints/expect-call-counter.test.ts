// Every expect matcher must bump the test runner's expect-call counter so
// `expect.assertions(n)` / `expect.hasAssertions()` work.
import { Glob } from "bun";
import { expect, test } from "bun:test";
import { readFileSync } from "fs";
import { basename, join } from "path";

const MATCHER_DIR = join(import.meta.dir, "../../../src/test_runner/expect");

test("every expect matcher increments the expect-call counter", () => {
  const glob = new Glob("*.zig");
  const files = [...glob.scanSync({ cwd: MATCHER_DIR, absolute: true })].sort();
  const functions = new Map<string, string>();
  for (const file of files) {
    const source = readFileSync(file, "utf8");
    const module = basename(file, ".zig");
    // Top-level Zig function bodies end at an unindented closing brace.
    for (const match of source.matchAll(/^(?:pub )?fn (\w+)\([\s\S]*?^}/gm)) {
      functions.set(`${module}.${match[1]}`, match[0].slice(match[0].indexOf("{") + 1, -1));
    }
  }

  const missing: string[] = [];
  function check(name: string, ancestors: string[] = []) {
    const body = functions.get(name);
    if (body === undefined || ancestors.includes(name)) {
      missing.push([...ancestors, name].join(" -> "));
      return;
    }
    if (/\b(?:incrementExpectCallCounter|CounterEngine\.increment)\(/.test(body)) {
      return;
    }

    const module = name.slice(0, name.indexOf("."));
    const delegates = new Set(
      [...body.matchAll(/\b(?:(\w+)\.)?(\w+)\(/g)]
        .map(match => `${match[1] ?? module}.${match[2]}`)
        .filter(callee => functions.has(callee)),
    );
    if (delegates.size === 0) missing.push([...ancestors, name].join(" -> "));
    for (const delegate of delegates) check(delegate, [...ancestors, name]);
  }

  check("MatcherEngine.run");
  check("CustomMatcherEngine.apply");
  expect(missing).toEqual([]);
});
