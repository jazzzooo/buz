import { Buffer } from "node:buffer";

const previewLimit = 64 * 1024;
const diagnosticLimit = 64 * 1024;
const omitted = "\n[diagnostic truncated; see streamed output]\n";

function copyText(text) {
  // Parsed substrings must not retain the entire subprocess output.
  return Buffer.from(text, "utf16le").toString("utf16le");
}

function boundedText(text, limit) {
  if (text.length <= limit) return copyText(text);
  const head = Math.floor(limit / 2);
  const tail = limit - head;
  return copyText(text.slice(0, head) + omitted + (tail ? text.slice(-tail) : ""));
}

export function compactTestResult(result) {
  const visited = new Set();
  let remaining = diagnosticLimit;
  let truncated = Boolean(result.diagnosticsTruncated);

  function visit(object) {
    if (!object || typeof object !== "object" || visited.has(object)) return;
    visited.add(object);
    for (const key of Object.keys(object)) {
      const value = object[key];
      if (typeof value !== "string") {
        visit(value);
        continue;
      }
      if (key === "stdout" || key === "stdoutPreview") {
        truncated ||= value.length > previewLimit;
        object[key] = boundedText(value, previewLimit);
      } else if (key === "stack" || key === "error" || (key === "name" && typeof object.stack === "string")) {
        const limit = Math.min(8192, remaining);
        truncated ||= value.length > limit;
        object[key] = boundedText(value, limit);
        remaining -= Math.min(value.length, limit);
      } else {
        object[key] = copyText(value);
      }
    }
  }

  visit(result);
  result.diagnosticsTruncated = truncated;
  return result;
}

export function summarizeTestResult(result) {
  return {
    testPath: result.testPath,
    ok: result.ok,
    status: result.status,
    error: result.error,
    exitCode: result.exitCode,
    signalCode: result.signalCode,
    duration: result.duration,
    captureTruncated: result.captureTruncated,
    diagnosticsTruncated: result.diagnosticsTruncated,
    stdoutPreview: result.stdoutPreview?.slice?.(-4000),
  };
}
