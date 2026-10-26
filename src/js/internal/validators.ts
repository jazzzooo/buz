const { hideFromStack } = require("internal/shared");

const RegExpPrototypeExec = RegExp.prototype.exec;
const ArrayIsArray = Array.isArray;
const ArrayBufferIsView = ArrayBuffer.isView;
const MathMax = Math.max;
const NumberIsFinite = Number.isFinite;
const NumberIsInteger = Number.isInteger;
const NumberIsNaN = Number.isNaN;
const ObjectIs = Object.is;
const ObjectPrototypeHasOwnProperty = Object.prototype.hasOwnProperty;
const StringPrototypeToLowerCase = String.prototype.toLowerCase;
const StringPrototypeToUpperCase = String.prototype.toUpperCase;
const StringPrototypeTrim = String.prototype.trim;

const tokenRegExp = /^[\^_`a-zA-Z\-0-9!#$%&'*+.|~]+$/;
/**
 * Verifies that the given val is a valid HTTP token
 * per the rules defined in RFC 7230
 * See https://tools.ietf.org/html/rfc7230#section-3.2.6
 */
function checkIsHttpToken(val) {
  return RegExpPrototypeExec.$call(tokenRegExp, val) !== null;
}

/*
  The rules for the Link header field are described here:
  https://www.rfc-editor.org/rfc/rfc8288.html#section-3

  This regex validates any string surrounded by angle brackets
  (not necessarily a valid URI reference) followed by zero or more
  link-params separated by semicolons.
*/
const linkValueRegExp = /^(?:<[^>]*>)(?:\s*;\s*[^;"\s]+(?:=(")?[^;"\s]*\1)?)*$/;
function validateLinkHeaderFormat(value, name) {
  if (typeof value === "undefined" || !RegExpPrototypeExec.$call(linkValueRegExp, value)) {
    throw $ERR_INVALID_ARG_VALUE(
      name,
      value,
      `must be an array or string of format "</styles.css>; rel=preload; as=style"`,
    );
  }
}

function validateLinkHeaderValue(hints) {
  if (typeof hints === "string") {
    validateLinkHeaderFormat(hints, "hints");
    return hints;
  } else if (ArrayIsArray(hints)) {
    const hintsLength = hints.length;
    let result = "";

    if (hintsLength === 0) {
      return result;
    }

    for (let i = 0; i < hintsLength; i++) {
      const link = hints[i];
      validateLinkHeaderFormat(link, "hints");
      result += link;

      if (i !== hintsLength - 1) {
        result += ", ";
      }
    }

    return result;
  }

  throw $ERR_INVALID_ARG_VALUE(
    "hints",
    hints,
    `must be an array or string of format "</styles.css>; rel=preload; as=style"`,
  );
}

function validateString(value, name) {
  if (typeof value !== "string") throw $ERR_INVALID_ARG_TYPE(name, "string", value);
}

function validateFunction(value, name) {
  if (typeof value !== "function") throw $ERR_INVALID_ARG_TYPE(name, "function", value);
}

function validateBoolean(value, name) {
  if (typeof value !== "boolean") throw $ERR_INVALID_ARG_TYPE(name, "boolean", value);
}

function validateObject(value, name) {
  if (value === null || typeof value !== "object" || ArrayIsArray(value)) {
    throw $ERR_INVALID_ARG_TYPE(name, "object", value);
  }
}

function validateInteger(value, name, min = Number.MIN_SAFE_INTEGER, max = Number.MAX_SAFE_INTEGER) {
  if (typeof value !== "number") throw $ERR_INVALID_ARG_TYPE(name, "number", value);
  min = Number(min);
  max = MathMax(min, Number(max));
  if (!NumberIsInteger(value)) throw $ERR_OUT_OF_RANGE(name, "an integer", value);
  if (value < min || value > max) throw $ERR_OUT_OF_RANGE(name, `>= ${min} and <= ${max}`, value);
}

function validateNumber(value, name, min?, max?) {
  if (typeof value !== "number") throw $ERR_INVALID_ARG_TYPE(name, "number", value);

  const minNumber = Number(min);
  const maxNumber = Number(max);
  const hasMin = min !== undefined && min !== null;
  const hasMax = max !== undefined && max !== null;
  if (
    (!hasMin || value >= minNumber) &&
    (!hasMax || value <= maxNumber) &&
    (!(hasMin || hasMax) || !NumberIsNaN(value))
  ) {
    return;
  }

  if (hasMin && hasMax) throw $ERR_OUT_OF_RANGE(name, `>= ${minNumber} and <= ${maxNumber}`, value);
  if (hasMin) throw $ERR_OUT_OF_RANGE(name, `>= ${minNumber}`, value);
  if (hasMax) throw $ERR_OUT_OF_RANGE(name, `<= ${maxNumber}`, value);
}

function validateFiniteNumber(value, name) {
  if (value === undefined || NumberIsNaN(value)) return false;
  if (typeof value !== "number") throw $ERR_INVALID_ARG_TYPE(name, "number", value);
  if (NumberIsFinite(value)) return true;
  throw $ERR_OUT_OF_RANGE(name, "a finite number", value);
}

function checkRangesOrGetDefault(value, name, lower, upper, defaultValue?) {
  if (!validateFiniteNumber(value, name)) return defaultValue;
  const lowerNumber = Number(lower);
  const upperNumber = Number(upper);
  if (value < lowerNumber || value > upperNumber) {
    throw $ERR_OUT_OF_RANGE(name, `>= ${lowerNumber} and <= ${upperNumber}`, value);
  }
  return value;
}

function validatePort(port, name = "Port", allowZero = true) {
  if (typeof port !== "number" && typeof port !== "string") {
    throw $ERR_SOCKET_BAD_PORT(`${name} should be ${allowZero ? ">=" : ">"} 0 and < 65536. Received ${port}`);
  }
  if (typeof port === "string" && StringPrototypeTrim.$call(port).length === 0) {
    throw $ERR_SOCKET_BAD_PORT(`${name} should be ${allowZero ? ">=" : ">"} 0 and < 65536. Received ${port}`);
  }

  const numericPort = Number(port);
  if (!NumberIsInteger(numericPort) || numericPort < 0 || numericPort > 0xffff || (numericPort === 0 && !allowZero)) {
    throw $ERR_SOCKET_BAD_PORT(`${name} should be ${allowZero ? ">=" : ">"} 0 and < 65536. Received ${port}`);
  }
  return port;
}

function validateAbortSignal(signal, name) {
  if (signal === undefined) return;
  if ((typeof signal !== "object" && typeof signal !== "function") || signal === null || !("aborted" in signal)) {
    throw $ERR_INVALID_ARG_TYPE(name, "AbortSignal", signal);
  }
}

function validateArray(value, name, minLength = 0) {
  if (!ArrayIsArray(value)) throw $ERR_INVALID_ARG_TYPE(name, "Array", value);
  const minimum = Number(minLength);
  if (value.length < minimum) throw $ERR_INVALID_ARG_VALUE(name, value, `must be longer than ${minimum}`);
}

function validateInt32(value, name, min = -2147483648, max = 2147483647) {
  if (typeof value !== "number") throw $ERR_INVALID_ARG_TYPE(name, "number", value);
  min = Number(min);
  max = Number(max);
  if (!NumberIsInteger(value)) throw $ERR_OUT_OF_RANGE(name, "an integer", value);
  if (value < min || value > max) throw $ERR_OUT_OF_RANGE(name, `>= ${min} and <= ${max}`, value);
}

function validateUint32(value, name, positive = false) {
  if (typeof value !== "number") throw $ERR_INVALID_ARG_TYPE(name, "number", value);
  if (!NumberIsInteger(value)) throw $ERR_OUT_OF_RANGE(name, "an integer", value);
  const min = positive ? 1 : 0;
  if (value < min || value > 0xffffffff) throw $ERR_OUT_OF_RANGE(name, `>= ${min} and <= 4294967295`, value);
}

function validateSignalName(signal, name = "signal") {
  validateString(signal, name);
  const signals = $processBindingConstants.os.signals;
  if (ObjectPrototypeHasOwnProperty.$call(signals, signal)) return;
  const uppercase = StringPrototypeToUpperCase.$call(signal);
  const suffix = ObjectPrototypeHasOwnProperty.$call(signals, uppercase)
    ? " (signals must use all capital letters)"
    : "";
  throw $ERR_UNKNOWN_SIGNAL(`Unknown signal: ${signal}${suffix}`);
}

function validateEncoding(data, encoding) {
  if (typeof encoding !== "string" || StringPrototypeToLowerCase.$call(encoding) !== "hex") return;
  let length = 0;
  if (typeof data === "string") {
    length = data.length;
  } else if (ArrayBufferIsView(data)) {
    length = "length" in data ? (data as { length: number }).length : data.byteLength;
  } else if (data instanceof ArrayBuffer) {
    length = data.byteLength;
  } else if (data !== null && (typeof data === "object" || typeof data === "function")) {
    length = Number(data.length) || 0;
  }
  if (length % 2 !== 0) {
    throw $ERR_INVALID_ARG_VALUE("encoding", encoding, `is invalid for data of length ${length}`);
  }
}

function validateBuffer(value, name = "buffer") {
  if (value !== undefined && !ArrayBufferIsView(value)) {
    throw $ERR_INVALID_ARG_TYPE(name, "Buffer, TypedArray, or DataView", value);
  }
}

function validateOneOf(value, name, oneOf) {
  if (!ArrayIsArray(oneOf)) throw $ERR_INVALID_ARG_TYPE("values", "Array", oneOf);
  for (let i = 0; i < oneOf.length; i++) {
    if (ObjectIs(value, oneOf[i])) return;
  }
  throw $bindgenFn("ErrorCode.schema.zig", "invalidOneOfError")(name, value, oneOf);
}

function validateUndefined(value, name) {
  if (value !== undefined) throw $ERR_INVALID_ARG_TYPE(name, "undefined", value);
}

function validateInternalField(object, fieldKey, className) {
  if (typeof object !== "object" || object === null || !ObjectPrototypeHasOwnProperty.$call(object, fieldKey)) {
    throw $ERR_INVALID_ARG_TYPE("this", className, object);
  }
}

hideFromStack(
  validateLinkHeaderValue,
  validateInternalField,
  validateString,
  validateFunction,
  validateBoolean,
  validateUndefined,
  validateObject,
  validateInteger,
  validateNumber,
  validateFiniteNumber,
  checkRangesOrGetDefault,
  validatePort,
  validateAbortSignal,
  validateArray,
  validateInt32,
  validateUint32,
  validateSignalName,
  validateEncoding,
  validateBuffer,
  validateOneOf,
);

export default {
  /** (value, name) */
  validateObject,
  validateLinkHeaderValue: validateLinkHeaderValue,
  checkIsHttpToken: checkIsHttpToken,
  /** `(value, name, min, max)` */
  validateInteger,
  /** `(value, name, min, max)` */
  validateNumber,
  /** `(value, name)` */
  validateString,
  /** `(number, name)` */
  validateFiniteNumber,
  /** `(number, name, lower, upper, def)` */
  checkRangesOrGetDefault,
  /** `(value, name)` */
  validateFunction,
  /** `(value, name)` */
  validateBoolean,
  /** `(port, name = 'Port', allowZero = true)` */
  validatePort,
  /** `(signal, name)` */
  validateAbortSignal,
  /** `(value, name, minLength = 0)` */
  validateArray,
  /** `(value, name, min = -2147483648, max = 2147483647)` */
  validateInt32,
  /** `(value, name, positive = false)` */
  validateUint32,
  /** `(signal, name = 'signal')` */
  validateSignalName,
  /** `(data, encoding)` */
  validateEncoding,
  /** `(value, name)` */
  validatePlainFunction: validateFunction,
  /** `(value, name)` */
  validateUndefined,
  /** `(buffer, name = 'buffer')` */
  validateBuffer,
  /** `(value, name, oneOf)` */
  validateOneOf,
  isUint8Array: value => value instanceof Uint8Array,
  /** `(object, fieldKey, className)` */
  validateInternalField,
};
