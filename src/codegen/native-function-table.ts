import fs from "fs";

interface BindgenCall {
  id: number;
  kind: "function" | "class";
  source: string;
  name: string;
  cppSymbol: string;
}

const calls: BindgenCall[] = [];
const links = new Map<string, Omit<BindgenCall, "id">>();
let configured = false;

export interface ErrorCodeMetadata {
  tag: string;
  value: number;
  code: string;
  name: string;
  constructor: "Error" | "TypeError" | "RangeError" | "SyntaxError" | "URIError";
}

interface BindgenLinkMetadata {
  version: number;
  fingerprint: string;
  entries: Array<{
    kind: "function" | "class";
    source: string;
    name: string;
    symbol: string;
  }>;
  errorCodes: ErrorCodeMetadata[];
}

let errorCodes: readonly ErrorCodeMetadata[] = [];

export function getErrorCodeMetadata() {
  if (!configured) throw new Error("Bindgen link metadata has not been configured");
  return errorCodes;
}

function linkKey(kind: BindgenCall["kind"], source: string, name: string) {
  return `${kind}\0${source}\0${name}`;
}

export function configureBindgenLinkMetadata(filename: string) {
  if (configured) throw new Error("Bindgen link metadata is already configured");
  const metadata = JSON.parse(fs.readFileSync(filename, "utf8")) as BindgenLinkMetadata;
  if (
    metadata.version !== 2 ||
    typeof metadata.fingerprint !== "string" ||
    !/^bun_bindgen_fingerprint_[0-9a-f]{16}$/.test(metadata.fingerprint) ||
    !Array.isArray(metadata.entries) ||
    !Array.isArray(metadata.errorCodes)
  ) {
    throw new Error(`Invalid bindgen link metadata: ${filename}`);
  }
  for (const entry of metadata.entries) {
    if (
      (entry.kind !== "function" && entry.kind !== "class") ||
      typeof entry.source !== "string" ||
      !entry.source.endsWith(".schema.zig") ||
      typeof entry.name !== "string" ||
      typeof entry.symbol !== "string" ||
      !/^[A-Za-z_][A-Za-z0-9_]*$/.test(entry.symbol)
    ) {
      throw new Error(`Invalid bindgen link entry in ${filename}`);
    }
    const key = linkKey(entry.kind, entry.source, entry.name);
    if (links.has(key)) {
      throw new Error(`Duplicate bindgen link entry for ${entry.kind} ${entry.source}:${entry.name}`);
    }
    links.set(key, {
      kind: entry.kind,
      source: entry.source,
      name: entry.name,
      cppSymbol: entry.symbol,
    });
  }
  const errorTags = new Set<string>();
  for (const [index, error] of metadata.errorCodes.entries()) {
    if (
      typeof error.tag !== "string" ||
      !/^[A-Za-z_][A-Za-z0-9_]*$/.test(error.tag) ||
      errorTags.has(error.tag) ||
      error.value !== index ||
      error.value > 0xffff ||
      typeof error.code !== "string" ||
      !/^[A-Za-z_][A-Za-z0-9_]*$/.test(error.code) ||
      typeof error.name !== "string" ||
      !["Error", "TypeError", "RangeError", "SyntaxError", "URIError"].includes(error.constructor)
    ) {
      throw new Error(`Invalid bindgen error code in ${filename}`);
    }
    errorTags.add(error.tag);
  }
  errorCodes = metadata.errorCodes;
  configured = true;
  return metadata.fingerprint;
}

export function registerBindgenFunction(filename: string, symbol: string) {
  return registerBindgenCall("function", filename, symbol);
}

export function registerBindgenClass(filename: string, symbol: string) {
  return registerBindgenCall("class", filename, symbol);
}

function registerBindgenCall(kind: BindgenCall["kind"], filename: string, symbol: string) {
  if (!configured) throw new Error("Bindgen link metadata has not been configured");
  const intrinsic = kind === "function" ? "$bindgenFn" : "$bindgenClass";
  const source = filename.replaceAll("\\", "/");
  const link = links.get(linkKey(kind, source, symbol));
  if (!link) {
    throw new Error(
      `Could not resolve ${intrinsic}(${JSON.stringify(filename)}, ${JSON.stringify(symbol)}) from generated link metadata`,
    );
  }
  const existing = calls.find(call => call.kind === kind && call.source === source && call.name === symbol);
  if (existing) return existing.id;

  const id = calls.length;
  calls.push({ id, ...link });
  return id;
}

export function getBindgenFunctionTableCPP() {
  return [
    `#pragma once`,
    `#include "SchemaBindings.h"`,
    `namespace BindgenBuiltinFactories {`,
    `using namespace Bun;`,
    `using namespace JSC;`,
    `using namespace WebCore;`,
    `static ALWAYS_INLINE JSC::JSValue resolve(int32_t index, Zig::GlobalObject* global) {`,
    `  switch (index) {`,
    ...calls.map(call => `    case ${call.id}: return ${call.cppSymbol}(global);`),
    `    default: __builtin_unreachable();`,
    `  }`,
    `}`,
    `#define BINDGEN_BUILTIN_FACTORY_COUNT ${calls.length}`,
    `}`,
  ].join("\n");
}
