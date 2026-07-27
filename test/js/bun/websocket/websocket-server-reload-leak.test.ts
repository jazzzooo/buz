import { expect, test } from "bun:test";
import { bunEnv, bunExe } from "harness";

test("server.reload() replaces and releases websocket configs lacking open/message", async () => {
  const script = /* js */ `
    const { heapStats, fullGC } = require("bun:jsc");

    const server = Bun.serve({
      port: 0,
      fetch(req, server) {
        if (server.upgrade(req)) return;
        return new Response("ok");
      },
      websocket: { message() {} },
    });

    const asyncFunctions = () => heapStats().objectTypeCounts.AsyncFunction ?? 0;
    const before = asyncFunctions();
    const client = new WebSocket(server.url);
    await new Promise((resolve, reject) => {
      client.onopen = resolve;
      client.onerror = reject;
    });

    const ITERS = 200;
    let closedBy = -1;
    for (let i = 0; i < ITERS; i++) {
      server.reload({
        fetch(req, server) {
          if (server.upgrade(req)) return;
          return new Response("ok");
        },
        websocket: {
          async close() {
            closedBy = i;
          },
        },
      });
    }

    for (let i = 0; i < 10; i++) {
      Bun.gc(true);
      fullGC();
      await new Promise(resolve => setImmediate(resolve));
    }
    const after = asyncFunctions();

    const closed = new Promise(resolve => {
      client.onclose = resolve;
    });
    client.close();
    await closed;
    server.stop(true);

    console.log(JSON.stringify({ before, after, closedBy, iters: ITERS }));
  `;

  await using proc = Bun.spawn({
    cmd: [bunExe(), "-e", script],
    env: bunEnv,
    stdout: "pipe",
    stderr: "pipe",
  });

  const [stdout, stderr, exitCode] = await Promise.all([proc.stdout.text(), proc.stderr.text(), proc.exited]);

  expect(stderr).toBe("");
  const { before, after, closedBy, iters } = JSON.parse(stdout.trim());
  expect(closedBy).toBe(iters - 1);
  expect(after - before).toBeLessThan(iters);
  expect(exitCode).toBe(0);
});
