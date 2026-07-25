import { expect, test } from "bun:test";
import { getSecret, isDockerEnabled } from "../harness";
import { ensure } from "./index";

const environmentNames = [
  "BUN_DOCKER_COORDINATOR",
  "BUN_TEST_SERVICE_postgres_plain",
  "CI",
  "TEST_OPTIONAL_SECRET",
] as const;

function restoreEnvironment(snapshot: Map<string, string | undefined>) {
  for (const [name, value] of snapshot) {
    if (value === undefined) {
      delete process.env[name];
    } else {
      process.env[name] = value;
    }
  }
}

test.serial("the repository runner never falls back to direct Compose", async () => {
  const snapshot = new Map(environmentNames.map(name => [name, process.env[name]]));
  try {
    process.env.BUN_DOCKER_COORDINATOR = "";
    delete process.env.BUN_TEST_SERVICE_postgres_plain;

    expect(isDockerEnabled()).toBe(false);
    await expect(ensure("postgres_plain")).rejects.toThrow("requires the test runner's coordinator");

    process.env.BUN_DOCKER_COORDINATOR = `/tmp/missing-bun-docker-${process.pid}.sock`;
    expect(isDockerEnabled()).toBe(true);
    await expect(ensure("postgres_plain")).rejects.toThrow("requires the test runner's coordinator");

    process.env.BUN_DOCKER_COORDINATOR = "";
    process.env.BUN_TEST_SERVICE_postgres_plain = "127.0.0.1:5432";
    expect(await ensure("postgres_plain")).toEqual({
      host: "127.0.0.1",
      ports: { 5432: 5432 },
    });
  } finally {
    restoreEnvironment(snapshot);
  }
});

test.serial("external secrets are optional independently of CI", () => {
  const snapshot = new Map(environmentNames.map(name => [name, process.env[name]]));
  try {
    process.env.CI = "true";
    delete process.env.TEST_OPTIONAL_SECRET;
    expect(getSecret("TEST_OPTIONAL_SECRET")).toBeUndefined();

    process.env.TEST_OPTIONAL_SECRET = " value ";
    expect(getSecret("TEST_OPTIONAL_SECRET")).toBe("value");
  } finally {
    restoreEnvironment(snapshot);
  }
});
