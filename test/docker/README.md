# Docker test services

The repository runner checks that the Docker daemon and Compose V2 are usable, then starts one coordinator process. Test processes request services over its Unix socket.

Run Compose-backed tests through the repository runner:

```sh
node scripts/runner.node.mjs --exec-path ./zig-out/bin/bun js/sql
```

Direct `bun test` invocations retain the original behavior: they check Docker and invoke Compose themselves.

## Adding tests

Prefer `describeWithContainer` from `test/harness.ts`:

```ts
describeWithContainer("postgres", { image: "postgres_plain" }, container => {
  test("connects", async () => {
    await container.ready;
    const url = `postgres://bun_sql_test@${container.host}:${container.port}/bun_sql_test`;
  });
});
```

Tests that need the richer service metadata returned by `test/docker/index.ts` should use the existing Docker gate:

```ts
if (isDockerEnabled()) {
  const info = await dockerCompose.ensure("redis_unified");
}
```

Add the test path and service to `prestart-map.mjs` so startup overlaps with earlier tests. Missing map entries remain correct but start the service only when first requested.

Available services are defined in `docker-compose.yml`:

- `postgres_plain`, `postgres_tls`, and `postgres_auth`
- `mysql_plain`, `mysql_native_password`, and `mysql_tls`
- `redis_plain` and `redis_unified`
- `minio`, `autobahn`, and `squid`

## External service mappings

`BUN_TEST_SERVICE_<name>` bypasses the coordinator for a specific service. A value may be a host, `host:port`, or `host:container-port=host-port,...`.

```sh
BUN_TEST_SERVICE_postgres_plain=127.0.0.1:5432 \
  ./zig-out/bin/bun test test/js/sql/sql.test.ts
```

## Inspecting and cleaning up

```sh
docker compose -p bun-test-services -f test/docker/docker-compose.yml ps
docker compose -p bun-test-services -f test/docker/docker-compose.yml logs postgres_plain
docker compose -p bun-test-services -f test/docker/docker-compose.yml down --volumes
```
