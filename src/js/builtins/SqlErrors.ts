// @internal

import type { MySQLErrorOptions, PostgresErrorOptions } from "internal/sql/errors";

export function createMySQLError(payload: MySQLErrorOptions & { message: string }) {
  const { MySQLError } = require("internal/sql/errors");
  return new MySQLError(payload.message, payload);
}

export function createPostgresError(payload: PostgresErrorOptions & { message: string }) {
  const { PostgresError } = require("internal/sql/errors");
  return new PostgresError(payload.message, payload);
}
