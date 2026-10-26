type ShellTemplateAtom = {
  kind: "escaped-text" | "raw-text" | "object" | "separator";
  text: string;
  value: unknown;
};
export type ShellTemplateValue = { atoms: ShellTemplateAtom[] };

const ArrayIsArray = Array.isArray;
const ArrayBufferIsView = ArrayBuffer.isView;
const ObjectPrototypeHasOwnProperty = Object.prototype.hasOwnProperty;

export function normalizeShellTemplateValue(input: unknown): ShellTemplateValue {
  const atoms: ShellTemplateAtom[] = [];

  function append(value: any) {
    if (
      ArrayBufferIsView(value) ||
      value instanceof ArrayBuffer ||
      value instanceof Blob ||
      value instanceof ReadableStream ||
      value instanceof Response
    ) {
      atoms.push({ kind: "object", text: "", value });
      return;
    }

    if (typeof value === "string") {
      atoms.push({ kind: "escaped-text", text: value, value: undefined });
      return;
    }

    if (ArrayIsArray(value)) {
      for (let index = 0; index < value.length; index++) {
        append(value[index]);
        if (index + 1 < value.length) atoms.push({ kind: "separator", text: "", value: undefined });
      }
      return;
    }

    if ((typeof value === "object" && value !== null) || typeof value === "function") {
      if (ObjectPrototypeHasOwnProperty.$call(value, "raw")) {
        const raw = value.raw;
        if (raw !== undefined) {
          atoms.push({ kind: "raw-text", text: String(raw), value: undefined });
          return;
        }
      }

      const toString = value.toString;
      if (typeof toString === "function") {
        atoms.push({ kind: "escaped-text", text: String(value), value: undefined });
        return;
      }

      const text = String(value);
      throw new Error(`Invalid JS object used in shell: ${text}, you might need to call \`.toString()\` on it`);
    }

    atoms.push({ kind: "escaped-text", text: String(value), value: undefined });
  }

  append(input);
  return { atoms };
}

