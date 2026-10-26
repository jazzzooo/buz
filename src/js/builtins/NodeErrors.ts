$visibility = "Private";
export function makeErrorWithCode(code, arg0) {
  const createError = $bindgenFn("ErrorCode.schema.zig", "createFromMessage");
  const arg1 = arguments[2];
  const arg2 = arguments[3];
  let message;

  switch (code) {
    case "ERR_INVALID_ARG_TYPE": {
      const name = `${arg0}`;
      let expected;
      if ($isJSArray(arg1)) {
        const length = arg1.length;
        if (length === 0) throw new TypeError("Argument-type errors require at least one expected type");
        const values = [];
        for (let i = 0; i < length; i++) $putByValDirect(values, i, arg1[i]);
        expected = "";
        for (let i = 0; i < length; i++) {
          if (i > 0) expected += length === 2 ? " or " : i === length - 1 ? ", or " : ", ";
          expected += `${values[i]}`;
        }
      } else {
        expected = `${arg1}`;
      }
      return $bindgenFn("ErrorCode.schema.zig", "invalidArgTypeError")(name, expected, arg2);
    }
    case "ERR_INVALID_ARG_VALUE":
      return $bindgenFn("ErrorCode.schema.zig", "invalidArgValueError")(arg0, arg1, arg2);
    case "ERR_OUT_OF_RANGE":
      return $bindgenFn("ErrorCode.schema.zig", "outOfRangeError")(arg0, arg1, arg2);
    case "ERR_INVALID_RETURN_VALUE": {
      const expected = `${arg0}`;
      const name = `${arg1}`;
      const actual = $bindgenFn("ErrorCode.schema.zig", "describeValueType")(arg2);
      message = `Expected ${expected} to be returned from the "${name}" function but got ${actual}.`;
      break;
    }
    case "ERR_MISSING_ARGS": {
      const count = arguments.length - 1;
      if (count === 0) throw new TypeError("Missing-argument errors require at least one argument name");
      if (count === 1) {
        if ($isJSArray(arg0)) {
          const length = arg0.length;
          if (length === 0) throw new TypeError("Missing-argument errors require at least one argument name");
          message = "The ";
          for (let i = 0; i < length; i++) {
            if (i > 0) message += "or ";
            message += `"${arg0[i]}" `;
          }
          message += "argument must be specified";
        } else {
          message = `The "${arg0}" argument must be specified`;
        }
      } else if (count === 2) {
        message = `The "${arg0}" and "${arg1}" arguments must be specified`;
      } else {
        message = "The ";
        for (let i = 0; i < count; i++) {
          if (i === count - 1) message += "and ";
          message += `"${arguments[i + 1]}"`;
          if (i !== count - 1) message += ",";
          message += " ";
        }
        message += "arguments must be specified";
      }
      break;
    }
    case "ERR_INVALID_MIME_SYNTAX": {
      const part = `${arg0}`;
      const input = `${arg1}`;
      const position = arg2 | 0;
      message = `The MIME syntax for a ${part} in ${input} is invalid`;
      if (position !== -1) message += ` at ${position}`;
      break;
    }
    case "ERR_INVALID_ADDRESS_FAMILY": {
      const error = createError(code, `Invalid address family: ${arg0} ${arg1}:${arg2}`);
      $putByIdDirect(error, "host", arg1);
      $putByIdDirect(error, "port", arg2);
      return error;
    }
    case "ERR_TLS_CERT_ALTNAME_INVALID": {
      const error = createError(code, `Hostname/IP does not match certificate's altnames: ${arg0}`);
      $putByIdDirect(error, "reason", arg0);
      $putByIdDirect(error, "host", arg1);
      $putByIdDirect(error, "cert", arg2);
      return error;
    }
    case "ERR_INVALID_URL": {
      const error = createError(code, "Invalid URL");
      $putByIdDirect(error, "input", arg0);
      if (arg1 !== undefined && arg1 !== null) $putByIdDirect(error, "base", arg1);
      return error;
    }
    case "ERR_VM_MODULE_LINK_FAILURE": {
      const error = createError(code, arg0);
      $putByIdDirect(error, "cause", arg1);
      return error;
    }
    case "ERR_SSL_NO_CIPHER_MATCH": {
      const error = createError(code, "No cipher match");
      $putByIdDirect(error, "reason", "no cipher match");
      $putByIdDirect(error, "library", "SSL routines");
      return error;
    }
    case "ERR_INVALID_IP_ADDRESS":
      message = `Invalid IP address: ${arg0}`;
      break;
    case "ERR_UNKNOWN_ENCODING":
      message = `Unknown encoding: ${arg0}`;
      break;
    case "ERR_STREAM_DESTROYED":
      message = `Cannot call ${arg0} after a stream was destroyed`;
      break;
    case "ERR_METHOD_NOT_IMPLEMENTED":
      message = `The ${arg0} method is not implemented`;
      break;
    case "ERR_STREAM_ALREADY_FINISHED":
      message = `Cannot call ${arg0} after a stream was finished`;
      break;
    case "ERR_INVALID_STATE":
    case "ERR_INVALID_STATE_TypeError":
    case "ERR_INVALID_STATE_RangeError":
      message = `Invalid state: ${arg0}`;
      break;
    case "ERR_INVALID_PROTOCOL":
      message = `Protocol "${arg0}" not supported. Expected "${arg1}"`;
      break;
    case "ERR_BROTLI_INVALID_PARAM":
      message = `${arg0} is not a valid Brotli parameter`;
      break;
    case "ERR_BUFFER_TOO_LARGE":
      message = `Cannot create a Buffer larger than ${arg0} bytes`;
      break;
    case "ERR_UNHANDLED_ERROR":
      message = arg0 === undefined ? "Unhandled error." : `Unhandled error. (${arg0})`;
      break;
    case "ERR_INVALID_THIS":
      message = `Value of "this" must be of type ${arg0}`;
      break;
    case "ERR_BUFFER_OUT_OF_BOUNDS":
      message =
        arg0 === undefined ? "Attempt to access memory outside buffer bounds" : `"${arg0}" is outside of buffer bounds`;
      break;
    case "ERR_TLS_INVALID_PROTOCOL_VERSION":
      message = `${arg0} is not a valid ${arg1} TLS protocol version`;
      break;
    case "ERR_TLS_PROTOCOL_VERSION_CONFLICT":
      message = `TLS protocol version ${arg0} conflicts with secureProtocol ${arg1}`;
      break;
    case "ERR_USE_AFTER_CLOSE":
      message = `${arg0} was closed`;
      break;
    case "ERR_INVALID_HTTP_TOKEN":
      message = `${arg0} must be a valid HTTP token ["${arg1}"]`;
      break;
    case "ERR_HTTP2_INVALID_HEADER_VALUE":
    case "ERR_HTTP_INVALID_HEADER_VALUE":
      message = `Invalid value "${arg0}" for header "${arg1}"`;
      break;
    case "ERR_HTTP2_STATUS_INVALID":
    case "ERR_HTTP_INVALID_STATUS_CODE":
      message = `Invalid status code: ${arg0}`;
      break;
    case "ERR_HTTP2_INVALID_PSEUDOHEADER":
      message = `"${arg0}" is an invalid pseudoheader or is used incorrectly`;
      break;
    case "ERR_HTTP2_STREAM_ERROR":
      message = `Stream closed with error code ${arg0}`;
      break;
    case "ERR_HTTP2_SESSION_ERROR":
      message = `Session closed with error code ${arg0}`;
      break;
    case "ERR_HTTP2_PAYLOAD_FORBIDDEN":
      message = `Responses with ${arg0} status must not have a payload`;
      break;
    case "ERR_HTTP2_INVALID_INFO_STATUS":
      message = `Invalid informational status code: ${arg0}`;
      break;
    case "ERR_INVALID_CHAR":
      message = `Invalid character in ${arg0}`;
      if (arg1 !== undefined) message += ` ["${arg1}"]`;
      break;
    case "ERR_HTTP_HEADERS_SENT":
      message = `Cannot ${arg0} headers after they are sent to the client`;
      break;
    case "ERR_UNESCAPED_CHARACTERS":
      message = `${arg0} contains unescaped characters`;
      break;
    case "ERR_CRYPTO_INVALID_KEY_OBJECT_TYPE":
      message = `Invalid key object type ${arg0}, expected ${arg1}.`;
      break;
    case "ERR_CRYPTO_INCOMPATIBLE_KEY":
      message = `Incompatible ${arg0}: ${arg1}`;
      break;
    case "ERR_CHILD_PROCESS_IPC_REQUIRED":
      message = `Forked processes must have an IPC channel, missing value 'ipc' in ${arg0}`;
      break;
    case "ERR_INVALID_ASYNC_ID":
      message = `Invalid ${arg0} value: ${arg1}`;
      break;
    case "ERR_ASYNC_TYPE":
      message = `Invalid name for async "type": ${arg0}`;
      break;
    case "ERR_ASYNC_CALLBACK":
      message = `${arg0} must be a function`;
      break;
    case "ERR_AMBIGUOUS_ARGUMENT":
      message = `The "${arg0}" argument is ambiguous. ${arg1}`;
      break;
    case "ERR_INVALID_FD_TYPE":
      message = `Unsupported fd type: ${arg0}`;
      break;
    case "ERR_CHILD_PROCESS_STDIO_MAXBUFFER":
      message = `${arg0} maxBuffer length exceeded`;
      break;
    case "ERR_IP_BLOCKED":
      message = `IP(${arg0}) is blocked by net.BlockList`;
      break;
    case "ERR_VM_MODULE_STATUS":
      message = `Module status ${arg0}`;
      break;
    case "ERR_ZSTD_INVALID_PARAM":
      message = `${arg0} is not a valid zstd parameter`;
      break;
    case "ERR_IPC_DISCONNECTED":
      message = "IPC channel is already disconnected";
      break;
    case "ERR_SERVER_NOT_RUNNING":
      message = "Server is not running.";
      break;
    case "ERR_IPC_CHANNEL_CLOSED":
      message = "Channel closed.";
      break;
    case "ERR_SOCKET_BAD_TYPE":
      message = "Bad socket type specified. Valid types are: udp4, udp6";
      break;
    case "ERR_ZLIB_INITIALIZATION_FAILED":
      message = "Initialization failed";
      break;
    case "ERR_IPC_ONE_PIPE":
      message = "Child process can have only one IPC pipe";
      break;
    case "ERR_SOCKET_ALREADY_BOUND":
      message = "Socket is already bound";
      break;
    case "ERR_SOCKET_BAD_BUFFER_SIZE":
      message = "Buffer size must be a positive integer";
      break;
    case "ERR_SOCKET_DGRAM_IS_CONNECTED":
      message = "Already connected";
      break;
    case "ERR_SOCKET_DGRAM_NOT_CONNECTED":
      message = "Not connected";
      break;
    case "ERR_SOCKET_DGRAM_NOT_RUNNING":
      message = "Socket is not running";
      break;
    case "ERR_INVALID_CURSOR_POS":
      message = "Cannot set cursor row without setting its column";
      break;
    case "ERR_INVALID_HANDLE_TYPE":
      message = "This handle type cannot be sent";
      break;
    case "ERR_MULTIPLE_CALLBACK":
      message = "Callback called multiple times";
      break;
    case "ERR_STREAM_PREMATURE_CLOSE":
      message = "Premature close";
      break;
    case "ERR_STREAM_NULL_VALUES":
      message = "May not write null values to stream";
      break;
    case "ERR_STREAM_CANNOT_PIPE":
      message = "Cannot pipe, not readable";
      break;
    case "ERR_STREAM_WRITE_AFTER_END":
      message = "write after end";
      break;
    case "ERR_STREAM_UNSHIFT_AFTER_END_EVENT":
      message = "stream.unshift() after end event";
      break;
    case "ERR_STREAM_PUSH_AFTER_EOF":
      message = "stream.push() after EOF";
      break;
    case "ERR_STREAM_UNABLE_TO_PIPE":
      message = "Cannot pipe to a closed or destroyed stream";
      break;
    case "ERR_ILLEGAL_CONSTRUCTOR":
      message = "Illegal constructor";
      break;
    case "ERR_DIR_CLOSED":
      message = "Directory handle was closed";
      break;
    case "ERR_SERVER_ALREADY_LISTEN":
      message = "Listen method has been called more than once without closing.";
      break;
    case "ERR_SOCKET_CLOSED":
      message = "Socket is closed";
      break;
    case "ERR_SOCKET_CLOSED_BEFORE_CONNECTION":
      message = "Socket closed before the connection was established";
      break;
    case "ERR_TLS_RENEGOTIATION_DISABLED":
      message = "TLS session renegotiation disabled for this socket";
      break;
    case "ERR_UNAVAILABLE_DURING_EXIT":
      message = "Cannot call function in process exit handler";
      break;
    case "ERR_TLS_CERT_ALTNAME_FORMAT":
      message = "Invalid subject alternative name string";
      break;
    case "ERR_TLS_SNI_FROM_SERVER":
      message = "Cannot issue SNI from a TLS server-side socket";
      break;
    case "ERR_INVALID_URI":
      message = "URI malformed";
      break;
    case "ERR_HTTP2_PSEUDOHEADER_NOT_ALLOWED":
      message = "Cannot set HTTP/2 pseudo-headers";
      break;
    case "ERR_HTTP2_INFO_STATUS_NOT_ALLOWED":
      message = "Informational status codes cannot be used";
      break;
    case "ERR_HTTP2_HEADERS_SENT":
      message = "Response has already been initiated.";
      break;
    case "ERR_HTTP2_INVALID_STREAM":
      message = "The stream has been destroyed";
      break;
    case "ERR_HTTP2_NO_SOCKET_MANIPULATION":
      message = "HTTP/2 sockets should not be directly manipulated (e.g. read and written)";
      break;
    case "ERR_HTTP2_SOCKET_UNBOUND":
      message = "The socket has been disconnected from the Http2Session";
      break;
    case "ERR_HTTP2_MAX_PENDING_SETTINGS_ACK":
      message = "Maximum number of pending settings acknowledgements";
      break;
    case "ERR_HTTP2_INVALID_SESSION":
      message = "The session has been destroyed";
      break;
    case "ERR_HTTP2_TRAILERS_ALREADY_SENT":
      message = "Trailing headers have already been sent";
      break;
    case "ERR_HTTP2_TRAILERS_NOT_READY":
      message = "Trailing headers cannot be sent until after the wantTrailers event is emitted";
      break;
    case "ERR_HTTP2_SEND_FILE":
      message = "Directories cannot be sent";
      break;
    case "ERR_HTTP2_SEND_FILE_NOSEEK":
      message = "Offset or length can only be specified for regular files";
      break;
    case "ERR_HTTP2_PUSH_DISABLED":
      message = "HTTP/2 client has disabled push streams";
      break;
    case "ERR_HTTP2_HEADERS_AFTER_RESPOND":
      message = "Cannot specify additional headers after response initiated";
      break;
    case "ERR_HTTP2_STATUS_101":
      message = "HTTP status code 101 (Switching Protocols) is forbidden in HTTP/2";
      break;
    case "ERR_HTTP2_ALTSVC_INVALID_ORIGIN":
      message = "HTTP/2 ALTSVC frames require a valid origin";
      break;
    case "ERR_HTTP2_INVALID_ORIGIN":
      message = "HTTP/2 ORIGIN frames require a valid origin";
      break;
    case "ERR_HTTP2_ALTSVC_LENGTH":
      message = "HTTP/2 ALTSVC frames are limited to 16382 bytes";
      break;
    case "ERR_HTTP2_PING_LENGTH":
      message = "HTTP2 ping payload must be 8 bytes";
      break;
    case "ERR_HTTP2_OUT_OF_STREAMS":
      message = "No stream ID is available because maximum stream ID has been reached";
      break;
    case "ERR_HTTP_BODY_NOT_ALLOWED":
      message = "Adding content for this request method or response status is not allowed.";
      break;
    case "ERR_HTTP_SOCKET_ASSIGNED":
      message = "Socket already assigned";
      break;
    case "ERR_STREAM_RELEASE_LOCK":
      message = "Stream reader cancelled via releaseLock()";
      break;
    case "ERR_SOCKET_CONNECTION_TIMEOUT":
      message = "Socket connection timeout";
      break;
    case "ERR_TLS_HANDSHAKE_TIMEOUT":
      message = "TLS handshake timeout";
      break;
    case "ERR_VM_MODULE_ALREADY_LINKED":
      message = "Module has already been linked";
      break;
    case "ERR_VM_MODULE_CANNOT_CREATE_CACHED_DATA":
      message = "Cached data cannot be created for a module which has been evaluated";
      break;
    case "ERR_VM_MODULE_NOT_MODULE":
      message = "Provided module is not an instance of Module";
      break;
    case "ERR_VM_MODULE_DIFFERENT_CONTEXT":
      message = "Linked modules must use the same context";
      break;
    case "ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING":
      message = "A dynamic import callback was not specified.";
      break;
    case "ERR_TLS_ALPN_CALLBACK_WITH_PROTOCOLS":
      message = "The ALPNCallback and ALPNProtocols TLS options are mutually exclusive";
      break;
    case "ERR_HTTP2_TOO_MANY_CUSTOM_SETTINGS":
      message = "Number of custom settings exceeds MAX_ADDITIONAL_SETTINGS";
      break;
    case "ERR_HTTP2_CONNECT_AUTHORITY":
      message = ":authority header is required for CONNECT requests";
      break;
    case "ERR_HTTP2_CONNECT_SCHEME":
      message = "The :scheme header is forbidden for CONNECT requests";
      break;
    case "ERR_HTTP2_CONNECT_PATH":
      message = "The :path header is forbidden for CONNECT requests";
      break;
    case "ERR_HTTP2_TOO_MANY_INVALID_FRAMES":
      message = "Too many invalid HTTP/2 frames";
      break;
    case "ERR_HTTP2_PING_CANCEL":
      message = "HTTP2 ping cancelled";
      break;
    default:
      return createError(code, arg0);
  }

  return createError(code, message);
}
