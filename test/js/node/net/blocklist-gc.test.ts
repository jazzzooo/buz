import { expect, test } from "bun:test";
import { bunEnv, bunExe } from "harness";

// Each delivery owns a reference to the shared rules independently of the sender and other recipients.
test("BlockList survives GC after BroadcastChannel fan-out clone", async () => {
  await using proc = Bun.spawn({
    cmd: [
      bunExe(),
      "-e",
      `
        const { BlockList } = require("node:net");

        const sender = new BroadcastChannel("blocklist-gc");
        const recvA = new BroadcastChannel("blocklist-gc");
        const recvB = new BroadcastChannel("blocklist-gc");

        let bl = new BlockList();
        bl.addAddress("127.0.0.1");

        const received = [];
        const { promise, resolve } = Promise.withResolvers();
        const onmessage = e => {
          received.push(e.data);
          if (received.length === 2) resolve();
        };
        recvA.onmessage = onmessage;
        recvB.onmessage = onmessage;
        sender.postMessage(bl);
        await promise;

        // Keep one clone reachable, drop the original and the other clone so
        // their finalizers run and deref the shared backing.
        let kept = received[1];
        bl = null;
        received.length = 0;
        Bun.gc(true);
        Bun.gc(true);

        // Must not be a dangling pointer: visitChildren/estimatedSize runs here.
        Bun.gc(true);
        if (kept.rules.length !== 1) throw new Error("clone lost its rules");

        sender.close();
        recvA.close();
        recvB.close();
        console.log("ok");
      `,
    ],
    env: bunEnv,
    stdout: "pipe",
    stderr: "pipe",
  });

  const [stdout, stderr, exited] = await Promise.all([proc.stdout.text(), proc.stderr.text(), proc.exited]);
  const cleanedStderr = stderr
    .split("\n")
    .filter(line => line && !line.startsWith("WARNING: ASAN interferes"))
    .join("\n");
  expect(cleanedStderr).toBe("");
  expect(stdout.trim()).toBe("ok");
  expect(exited).toBe(0);
});
