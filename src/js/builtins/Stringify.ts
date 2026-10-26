// @internal
const enum StringifyFormat {
  JSON5,
  YAML,
  TOML,
}

interface StringifyWriter {
  parts: string[];
  length: number;
}

export function stringifyValueIsIgnored(value) {
  const type = typeof value;
  return type === "undefined" || type === "symbol" || type === "function";
}

export function unwrapStringifyValue(value) {
  if (value === null || typeof value !== "object" || $isArray(value)) return value;
  const unwrap = $bindgenFn("js_value_conversions.schema.zig", "unwrapBoxedPrimitive");
  return unwrap(value);
}

export function stringifyIndentation(space) {
  space = $unwrapStringifyValue(space);
  if (typeof space === "number") {
    return $stringSubstring.$call("          ", 0, space >= 1 ? (space >= 10 ? 10 : space | 0) : 0);
  }
  return typeof space === "string" ? $stringSubstring.$call(space, 0, 10) : "";
}

export function createStringifyWriter(): StringifyWriter {
  return { parts: [], length: 0 };
}

export function appendStringify(writer: StringifyWriter, text: string) {
  const length = writer.length + text.length;
  if (length > $MAX_STRING_LENGTH) throw new RangeError("Invalid string length");
  writer.length = length;
  const index = writer.parts.length;
  $putByValDirect(writer.parts, index, text);
  return index;
}

export function finishStringify(writer: StringifyWriter) {
  const parts = writer.parts;
  // Pairwise concatenation bounds rope depth without consulting Array.prototype.
  for (let length = parts.length; length > 1; ) {
    let next = 0;
    for (let i = 0; i < length; i += 2) {
      parts[next++] = i + 1 < length ? parts[i] + parts[i + 1] : parts[i];
    }
    parts.length = length = next;
  }
  return parts.length === 0 ? "" : parts[0];
}

export function quoteStringifyString(value: string, format: StringifyFormat) {
  const quote = format === StringifyFormat.JSON5 ? "'" : '"';
  const hex = format === StringifyFormat.TOML ? "0123456789ABCDEF" : "0123456789abcdef";
  let result = quote;
  let start = 0;
  for (let i = 0; i < value.length; i++) {
    const c = value.$charCodeAt(i);
    let escape;
    switch (c) {
      case 0x08:
        escape = "\\b";
        break;
      case 0x09:
        escape = "\\t";
        break;
      case 0x0a:
        escape = "\\n";
        break;
      case 0x0c:
        escape = "\\f";
        break;
      case 0x0d:
        escape = "\\r";
        break;
      case 0x5c:
        escape = "\\\\";
        break;
      default:
        if (value[i] === quote) {
          escape = "\\" + quote;
        } else if (format === StringifyFormat.TOML) {
          if (c < 0x20 || c === 0x7f) {
            escape = "\\u00" + hex[c >> 4] + hex[c & 15];
          } else if (c >= 0xd800 && c <= 0xdfff) {
            if (
              c <= 0xdbff &&
              i + 1 < value.length &&
              value.$charCodeAt(i + 1) >= 0xdc00 &&
              value.$charCodeAt(i + 1) <= 0xdfff
            ) {
              i++;
            } else {
              escape = "\ufffd";
            }
          }
        } else if (c === 0) {
          const next = i + 1 < value.length ? value.$charCodeAt(i + 1) : 0;
          escape = format === StringifyFormat.JSON5 && next >= 48 && next <= 57 ? "\\x00" : "\\0";
        } else if (c === 0x0b) {
          escape = "\\v";
        } else if (format === StringifyFormat.YAML && c === 0x07) {
          escape = "\\a";
        } else if (format === StringifyFormat.YAML && c === 0x1b) {
          escape = "\\e";
        } else if (c < 0x20 || c === 0x7f) {
          escape = "\\x" + hex[c >> 4] + hex[c & 15];
        } else if (format === StringifyFormat.YAML && c === 0x85) {
          escape = "\\N";
        } else if (format === StringifyFormat.YAML && c === 0xa0) {
          escape = "\\_";
        } else if (c === 0x2028) {
          escape = format === StringifyFormat.YAML ? "\\L" : "\\u2028";
        } else if (c === 0x2029) {
          escape = format === StringifyFormat.YAML ? "\\P" : "\\u2029";
        }
    }
    if (escape !== undefined) {
      result += $stringSubstring.$call(value, start, i) + escape;
      start = i + 1;
    }
  }
  return result + $stringSubstring.$call(value, start, value.length) + quote;
}

export function json5(value, replacer, space) {
  const createError = $bindgenFn("Stringify.schema.zig", "createError");
  if ($stringifyValueIsIgnored(value)) return undefined;
  if (replacer !== undefined && replacer !== null)
    throw createError("JSON5.stringify does not support the replacer argument");
  const gap = $stringifyIndentation(space);
  const writer = $createStringifyWriter();
  const ancestors = new $Set();
  const identifier = /^[$_\p{ID_Start}][$\u200c\u200d\p{ID_Continue}]*$/u;

  function write(input, indent) {
    if (input === null || typeof input === "boolean" || typeof input === "number") {
      $appendStringify(writer, "" + input);
      return;
    }
    if (typeof input === "string") {
      $appendStringify(writer, $quoteStringifyString(input, StringifyFormat.JSON5));
      return;
    }
    if (typeof input === "bigint") throw createError("JSON5.stringify cannot serialize BigInt");
    if (ancestors.$has(input)) throw createError("Converting circular structure to JSON5");
    ancestors.$add(input);
    const array = $isArray(input);
    const nextIndent = indent + gap;
    let count = 0;
    $appendStringify(writer, array ? "[" : "{");
    const keys = array ? undefined : $Object.$keys(input);
    const length = array ? input.length : keys!.length;
    for (let i = 0; i < length; i++) {
      const key = array ? i : keys![i];
      let item = $unwrapStringifyValue(input[key]);
      if ($stringifyValueIsIgnored(item)) {
        if (!array) continue;
        item = null;
      }
      if (count++) $appendStringify(writer, ",");
      if (gap) $appendStringify(writer, "\n" + nextIndent);
      if (!array) {
        const name =
          $regExpBuiltinExec.$call(identifier, key) !== null ? key : $quoteStringifyString(key, StringifyFormat.JSON5);
        $appendStringify(writer, name + (gap ? ": " : ":"));
      }
      write(item, nextIndent);
    }
    if (count && gap) $appendStringify(writer, ",\n" + indent);
    $appendStringify(writer, array ? "]" : "}");
    ancestors.$delete(input);
  }

  write($unwrapStringifyValue(value), "");
  return $finishStringify(writer);
}

export function yamlStringIsNumber(value) {
  const first = value[0];
  if (first !== "+" && first !== "-" && first !== "." && !(first >= "0" && first <= "9")) return false;
  let i = first === "+" || first === "-" ? 1 : 0;
  if (i === value.length) return false;
  if (i && value[i] === ".") {
    const suffix = $stringSubstring.$call(value, i + 1, i + 4);
    if (suffix === "inf" || suffix === "Inf" || suffix === "INF") return true;
  }
  let base = 10;
  if (value[i] === "0") {
    const prefix = value[i + 1];
    if (prefix === "x" || prefix === "X") base = 16;
    else if (prefix === "o" || prefix === "O") base = 8;
    if (base !== 10) i += 2;
  }
  if (i === value.length) return false;
  let dot = false;
  let exponent = false;
  let minus = false;
  // YAML's numeric parser accepts prefixes such as 1+5, which also need quoting.
  for (; i < value.length; i++) {
    const c = value[i];
    if (c >= "0" && c <= "9") continue;
    if (c === "e" || c === "E") {
      if (base === 10 && exponent) return false;
      exponent = true;
    } else if ((c >= "a" && c <= "f") || (c >= "A" && c <= "F")) {
      if (base !== 16) return false;
    } else if (c === ".") {
      if (dot || base !== 10) return false;
      dot = true;
    } else if (c === "+") {
      if (base === 16) return false;
    } else if (c === "-") {
      if (minus) return false;
      minus = true;
    } else return false;
  }
  return true;
}

export function yaml(value, replacer, space) {
  const createError = $bindgenFn("Stringify.schema.zig", "createError");
  if ($stringifyValueIsIgnored(value)) return undefined;
  if (replacer !== undefined && replacer !== null)
    throw createError("YAML.stringify does not support the replacer argument");
  const gap = $stringifyIndentation(space);
  const writer = $createStringifyWriter();
  const collections = new $Map();
  const usedNames = new $Set();
  usedNames.$add("root");
  const counters = new $Map();
  let itemCounter = 0;
  let valueCounter = 0;
  const unsafeAnchor = /[\x00-\x20\x7f\x85\xa0,\[\]{}\u0100-\uffff]/;
  const quoteRequired =
    /^(?:[&*?|\-<>!%@:,\[\]{}#'"` \t\r\n]|(?:true|True|TRUE|false|False|FALSE|yes|Yes|YES|no|No|NO|on|On|ON|off|Off|OFF|n|N|y|Y|null|Null|NULL|~|\.inf|\.Inf|\.INF|\.nan|\.NaN|\.NAN)$)|[ \t\r\n:]$|[\x00-\x1f"\x7f\x85\xa0\u2028\u2029{}\[\],#`']|:[ \t\r\n]|(?:---|\.\.\.)(?:$|[ \t\r\n\[\]{},])/;
  function string(input) {
    return input.length === 0 || $regExpBuiltinExec.$call(quoteRequired, input) !== null || $yamlStringIsNumber(input)
      ? $quoteStringifyString(input, StringifyFormat.YAML)
      : input;
  }

  function anchor(entry) {
    if (entry.name !== undefined) return entry.name;
    let name;
    if (entry.origin === null) {
      name = "root";
    } else if (entry.origin === undefined) {
      do {
        name = "item" + itemCounter++;
      } while (usedNames.$has(name));
    } else if (entry.origin.length === 0 || $regExpBuiltinExec.$call(unsafeAnchor, entry.origin) !== null) {
      do {
        name = "value" + valueCounter++;
      } while (usedNames.$has(name));
    } else {
      let counter = counters.$get(entry.origin) || 0;
      do {
        name = entry.origin + (counter === 0 ? "" : counter);
        counter++;
      } while (usedNames.$has(name));
      counters.$set(entry.origin, counter);
    }
    usedNames.$add(name);
    entry.name = name;
    const prefix = "&" + name + (gap ? "\n" + entry.indent : " ");
    if (writer.length + prefix.length > $MAX_STRING_LENGTH) throw new RangeError("Invalid string length");
    writer.length += prefix.length;
    writer.parts[entry.slot] = prefix;
    return name;
  }

  function write(input, indent, origin) {
    if (input === null || typeof input === "boolean") {
      $appendStringify(writer, "" + input);
      return;
    }
    if (typeof input === "number") {
      $appendStringify(
        writer,
        input !== input
          ? ".nan"
          : input === Infinity
            ? ".inf"
            : input === -Infinity
              ? "-.inf"
              : input === 0 && 1 / input < 0
                ? "-0"
                : "" + input,
      );
      return;
    }
    if (typeof input === "string") {
      $appendStringify(writer, string(input));
      return;
    }
    if (typeof input === "bigint") throw createError("YAML.stringify cannot serialize BigInt");
    const existing = collections.$get(input);
    if (existing !== undefined) {
      $appendStringify(writer, "*" + anchor(existing));
      return;
    }
    collections.$set(input, { slot: $appendStringify(writer, ""), indent, origin, name: undefined });
    const array = $isArray(input);
    const keys = array ? undefined : $Object.$keys(input);
    const length = array ? input.length : keys!.length;
    let count = 0;
    if (!gap) $appendStringify(writer, array ? "[" : "{");
    for (let i = 0; i < length; i++) {
      const key = array ? i : keys![i];
      const item = $unwrapStringifyValue(input[key]);
      if ($stringifyValueIsIgnored(item)) continue;
      if (count++) $appendStringify(writer, gap ? "\n" + indent : ",");
      if (array) {
        if (gap) $appendStringify(writer, "- ");
      } else {
        $appendStringify(writer, string(key) + ": ");
        if (gap && item !== null && typeof item === "object") $appendStringify(writer, "\n" + indent + gap);
      }
      write(item, indent + gap, array ? undefined : key);
    }
    if (!gap) $appendStringify(writer, array ? "]" : "}");
    else if (!count) $appendStringify(writer, array ? "[]" : "{}");
  }

  write($unwrapStringifyValue(value), "", null);
  return $finishStringify(writer);
}

export function toml(value, replacer, space) {
  const createError = $bindgenFn("Stringify.schema.zig", "createError");
  if ($stringifyValueIsIgnored(value)) return undefined;
  if (replacer !== undefined && replacer !== null)
    throw createError("TOML.stringify does not support the replacer argument");
  const stringifyDate = $bindgenFn("TOMLObject.schema.zig", "stringifyDate");
  const ancestors = new $Set();
  const bareKey = /^[a-zA-Z0-9_-]+$/;
  const floatMarker = /[.eE]/;

  function key(input) {
    return $regExpBuiltinExec.$call(bareKey, input) !== null
      ? input
      : $quoteStringifyString(input, StringifyFormat.TOML);
  }

  function enter(input) {
    if (ancestors.$has(input)) throw createError("Converting circular structure to TOML");
    ancestors.$add(input);
  }

  function prepare(input, array, name) {
    input = $unwrapStringifyValue(input);
    if (input === null) {
      if (array) throw createError("TOML cannot represent null in an array");
      throw createError("TOML cannot represent null (key '" + name + "'); remove the key or use a sentinel value");
    }
    switch (typeof input) {
      case "undefined":
      case "symbol":
      case "function":
        if (array) throw createError("TOML cannot represent undefined in an array");
        return undefined;
      case "bigint":
        throw createError("TOML.stringify cannot serialize BigInt");
      case "string":
        return $quoteStringifyString(input, StringifyFormat.TOML);
      case "boolean":
        return "" + input;
      case "number": {
        if (input !== input) return "nan";
        if (input === Infinity) return "inf";
        if (input === -Infinity) return "-inf";
        if (input === 0 && 1 / input < 0) return "-0.0";
        const text = "" + input;
        return (input > 9007199254740991 || input < -9007199254740991) &&
          $regExpBuiltinExec.$call(floatMarker, text) === null
          ? text + ".0"
          : text;
      }
      default:
        return $isArray(input) ? input : (stringifyDate(input) ?? input);
    }
  }

  function writeInline(input, writer) {
    if (typeof input === "string") {
      $appendStringify(writer, input);
      return;
    }
    enter(input);
    const array = $isArray(input);
    const keys = array ? undefined : $Object.$keys(input);
    const length = array ? input.length : keys!.length;
    let count = 0;
    $appendStringify(writer, array ? "[" : "{");
    for (let i = 0; i < length; i++) {
      const name = array ? i : keys![i];
      const item = prepare(input[name], array, name);
      if (item === undefined) continue;
      if (count++) $appendStringify(writer, ", ");
      else if (!array) $appendStringify(writer, " ");
      if (!array) $appendStringify(writer, key(name) + " = ");
      writeInline(item, writer);
    }
    $appendStringify(writer, array ? "]" : count ? " }" : "}");
    ancestors.$delete(input);
  }

  function table(input, path, header) {
    enter(input);
    const body = $createStringifyWriter();
    const tables = [];
    const arrays = [];
    const keys = $Object.$keys(input);
    for (let i = 0; i < keys.length; i++) {
      const name = keys[i];
      const item = prepare(input[name], false, name);
      if (item === undefined) continue;
      const quotedKey = key(name);
      const childPath = path === "" ? quotedKey : path + "." + quotedKey;
      if (typeof item === "string") {
        $appendStringify(body, quotedKey + " = " + item + "\n");
      } else if (!$isArray(item)) {
        $putByValDirect(tables, tables.length, table(item, childPath, "[" + childPath + "]"));
      } else {
        enter(item);
        const length = item.length;
        const items = [];
        let allTables = length > 0;
        for (let j = 0; j < length; j++) {
          const element = prepare(item[j], true, "");
          $putByValDirect(items, j, element);
          if (typeof element === "string" || $isArray(element)) allTables = false;
        }
        if (allTables) {
          for (let j = 0; j < length; j++) {
            $putByValDirect(arrays, arrays.length, table(items[j], childPath, "[[" + childPath + "]]"));
          }
        } else {
          $appendStringify(body, quotedKey + " = [");
          for (let j = 0; j < length; j++) {
            if (j) $appendStringify(body, ", ");
            writeInline(items[j], body);
          }
          $appendStringify(body, "]\n");
        }
        ancestors.$delete(item);
      }
    }
    ancestors.$delete(input);
    return { header, body, tables, arrays };
  }

  value = $unwrapStringifyValue(value);
  if (value === null || typeof value !== "object" || $isArray(value) || stringifyDate(value) !== undefined) {
    throw createError("TOML.stringify expects an object at the top level (a TOML document is a table)");
  }
  const document = table(value, "", "");
  const writer = $createStringifyWriter();
  function emit(section) {
    if (section.header !== "") {
      if (writer.length) $appendStringify(writer, "\n");
      $appendStringify(writer, section.header + "\n");
    }
    for (let i = 0; i < section.body.parts.length; i++) $appendStringify(writer, section.body.parts[i]);
    for (let i = 0; i < section.tables.length; i++) emit(section.tables[i]);
    for (let i = 0; i < section.arrays.length; i++) emit(section.arrays[i]);
  }
  emit(document);
  return $finishStringify(writer);
}

export function materializeParsedValueGraph(graph) {
  const nodes = graph.nodes;
  const edges = graph.edges;
  const values = $newArrayWithSize(nodes.length);
  const states = $newArrayWithSize(nodes.length);

  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i];
    switch (node.kind) {
      case "undefined":
        values[i] = undefined;
        states[i] = 2;
        break;
      case "nulled":
        values[i] = null;
        states[i] = 2;
        break;
      case "number":
        values[i] = node.number;
        states[i] = 2;
        break;
      case "boolean":
        values[i] = node.boolean;
        states[i] = 2;
        break;
      case "string":
        values[i] = node.text;
        states[i] = 2;
        break;
      case "array":
        values[i] = [];
        states[i] = 0;
        break;
      case "object":
        values[i] = {};
        states[i] = 0;
        break;
    }
  }

  function materialize(index) {
    if (states[index] !== 0) return values[index];
    states[index] = 1;

    const node = nodes[index];
    const value = values[index];
    const edgeEnd = node.edgeStart + node.edgeCount;
    if (node.kind === "array") {
      for (let edgeIndex = node.edgeStart, itemIndex = 0; edgeIndex < edgeEnd; edgeIndex++, itemIndex++) {
        $putByValDirect(value, itemIndex, materialize(edges[edgeIndex].target));
      }
    } else {
      for (let edgeIndex = node.edgeStart; edgeIndex < edgeEnd; edgeIndex++) {
        const edge = edges[edgeIndex];
        const key = materialize(edge.key);
        const target = materialize(edge.target);
        $putByValDirect(value, key, target);
      }
    }

    states[index] = 2;
    return value;
  }

  return materialize(graph.root);
}

export function parseJSON5(input) {
  const parseGraph = $bindgenFn("JSON5Object.schema.zig", "parseGraph");
  return $materializeParsedValueGraph(parseGraph(input));
}

export function parseJSONC(input) {
  const parseGraph = $bindgenFn("JSONCObject.schema.zig", "parseGraph");
  return $materializeParsedValueGraph(parseGraph(input));
}

export function parseTOML(input) {
  const parseGraph = $bindgenFn("TOMLObject.schema.zig", "parseGraph");
  return $materializeParsedValueGraph(parseGraph(input));
}

export function parseYAML(input) {
  const parseGraph = $bindgenFn("YAMLObject.schema.zig", "parseGraph");
  return $materializeParsedValueGraph(parseGraph(input));
}
