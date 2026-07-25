import { spawnSync } from "node:child_process";

const [execPath, ...args] = process.argv.slice(2);
if (!execPath) {
  throw new Error("Missing Bun executable");
}

const testHome = process.env.TEST_TMPDIR;
if (!testHome) {
  throw new Error("Missing test temporary directory");
}
const env = { ...process.env, HOME: testHome };
const login = spawnSync("gnome-keyring-daemon", ["--login", "--components=secrets"], {
  env,
  input: "bun-tests",
  encoding: "utf8",
});

if (login.error) {
  throw login.error;
}
if (login.status !== 0) {
  process.stderr.write(login.stderr);
  process.exit(login.status ?? 1);
}

const start = spawnSync("gnome-keyring-daemon", ["--start", "--components=secrets"], {
  env,
  encoding: "utf8",
});
if (start.error) {
  throw start.error;
}
if (start.status !== 0) {
  process.stderr.write(start.stderr);
  process.exit(start.status ?? 1);
}

const result = spawnSync(execPath, args, { env, stdio: "inherit" });
if (result.error) {
  throw result.error;
}
if (result.signal) {
  process.kill(process.pid, result.signal);
}
process.exit(result.status ?? 1);
