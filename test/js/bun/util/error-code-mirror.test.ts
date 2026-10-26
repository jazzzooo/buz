import { expect, test } from "bun:test";
import { bunEnv, bunExe } from "harness";

test("generated error codes round-trip through the typed engine binding", async () => {
  const fixture = `
    function t(fn) { try { fn(); console.log("NO THROW"); } catch (e) { console.log(e.code + ":" + e.constructor.name); } }
    async function ta(fn) { try { await fn(); console.log("NO THROW"); } catch (e) { console.log(e.code + ":" + e.constructor.name); } }
    t(() => require("crypto").timingSafeEqual(Buffer.alloc(1), Buffer.alloc(2)));
    t(() => new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array([0xff])));
    t(() => new TextDecoder("nope"));
    t(() => Bun.randomUUIDv5());
    t(() => Bun.randomUUIDv5("n", "bad-namespace"));
    t(() => Bun.S3Client.presign("f", { accessKeyId: "a", secretAccessKey: "b", bucket: "c", method: "PATCH" }));
    t(() => new (require("net").SocketAddress)({ port: 99999 }));
    t(() => Bun.randomUUIDv7("bogus"));
    await ta(() => new Response("x").formData());
  `;
  await using proc = Bun.spawn({
    cmd: [bunExe(), "-e", fixture],
    env: bunEnv,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([proc.stdout.text(), proc.stderr.text(), proc.exited]);
  // Assert the raw child output: if the C++ side reads past errors[] and the
  // child crashes, the diff here shows partial/empty stdout plus stderr instead
  // of a JSON parse error.
  expect({ stdout, stderr, exitCode, signalCode: proc.signalCode }).toEqual({
    stdout:
      [
        "ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH:RangeError",
        "ERR_ENCODING_INVALID_ENCODED_DATA:TypeError",
        "ERR_ENCODING_NOT_SUPPORTED:RangeError",
        "ERR_INVALID_ARG_TYPE:TypeError",
        "ERR_INVALID_ARG_VALUE:TypeError",
        "ERR_S3_INVALID_METHOD:Error",
        "ERR_SOCKET_BAD_PORT:RangeError",
        "ERR_UNKNOWN_ENCODING:TypeError",
        "ERR_FORMDATA_PARSE_ERROR:TypeError",
      ].join("\n") + "\n",
    stderr: "",
    exitCode: 0,
    signalCode: null,
  });
});
