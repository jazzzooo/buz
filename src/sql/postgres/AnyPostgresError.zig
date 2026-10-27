pub const AnyPostgresError = error{
    ConnectionClosed,
    ExpectedRequest,
    ExpectedStatement,
    InvalidBackendKeyData,
    InvalidBinaryData,
    InvalidByteSequence,
    InvalidByteSequenceForEncoding,
    InvalidCharacter,
    InvalidMessage,
    InvalidMessageLength,
    InvalidQueryBinding,
    InvalidServerKey,
    InvalidServerSignature,
    InvalidTimeFormat,
    JSError,
    JSTerminated,
    MultidimensionalArrayNotSupportedYet,
    NullsInArrayNotSupportedYet,
    OutOfMemory,
    Overflow,
    PBKDFD2,
    SASL_SIGNATURE_MISMATCH,
    SASL_SIGNATURE_INVALID_BASE64,
    ShortRead,
    TLSNotAvailable,
    TLSUpgradeFailed,
    TooManyParameters,
    UnexpectedMessage,
    UNKNOWN_AUTHENTICATION_METHOD,
    UNSUPPORTED_AUTHENTICATION_METHOD,
    UnsupportedByteaFormat,
    UnsupportedIntegerSize,
    UnsupportedArrayFormat,
    UnsupportedNumericFormat,
    UnknownFormatCode,
};

/// Options for creating a PostgresError
pub const PostgresErrorOptions = struct {
    code: []const u8,
    errno: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    severity: ?[]const u8 = null,
    position: ?[]const u8 = null,
    internalPosition: ?[]const u8 = null,
    internalQuery: ?[]const u8 = null,
    where: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
    dataType: ?[]const u8 = null,
    constraint: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?[]const u8 = null,
    routine: ?[]const u8 = null,
};

pub const ErrorDescription = struct {
    message: []const u8,
    options: PostgresErrorOptions,
};

pub fn describe(
    message: ?[]const u8,
    err: AnyPostgresError,
    message_buffer: *[256]u8,
) ErrorDescription {
    if (err == error.TooManyParameters) {
        return .{
            .message = "query has too many parameters - the PostgreSQL wire protocol supports a maximum of 65535 parameters per query. Try reducing your batch size.",
            .options = .{
                .code = "ERR_POSTGRES_TOO_MANY_PARAMETERS",
                .hint = "Reduce the number of rows in your batch insert so that total_rows * columns_per_row does not exceed 65535.",
            },
        };
    }

    const code = switch (err) {
        error.ConnectionClosed => "ERR_POSTGRES_CONNECTION_CLOSED",
        error.ExpectedRequest => "ERR_POSTGRES_EXPECTED_REQUEST",
        error.ExpectedStatement => "ERR_POSTGRES_EXPECTED_STATEMENT",
        error.InvalidBackendKeyData => "ERR_POSTGRES_INVALID_BACKEND_KEY_DATA",
        error.InvalidBinaryData => "ERR_POSTGRES_INVALID_BINARY_DATA",
        error.InvalidByteSequence => "ERR_POSTGRES_INVALID_BYTE_SEQUENCE",
        error.InvalidByteSequenceForEncoding => "ERR_POSTGRES_INVALID_BYTE_SEQUENCE_FOR_ENCODING",
        error.InvalidCharacter => "ERR_POSTGRES_INVALID_CHARACTER",
        error.InvalidMessage => "ERR_POSTGRES_INVALID_MESSAGE",
        error.InvalidMessageLength => "ERR_POSTGRES_INVALID_MESSAGE_LENGTH",
        error.InvalidQueryBinding => "ERR_POSTGRES_INVALID_QUERY_BINDING",
        error.InvalidServerKey => "ERR_POSTGRES_INVALID_SERVER_KEY",
        error.InvalidServerSignature => "ERR_POSTGRES_INVALID_SERVER_SIGNATURE",
        error.InvalidTimeFormat => "ERR_POSTGRES_INVALID_TIME_FORMAT",
        error.MultidimensionalArrayNotSupportedYet => "ERR_POSTGRES_MULTIDIMENSIONAL_ARRAY_NOT_SUPPORTED_YET",
        error.NullsInArrayNotSupportedYet => "ERR_POSTGRES_NULLS_IN_ARRAY_NOT_SUPPORTED_YET",
        error.Overflow => "ERR_POSTGRES_OVERFLOW",
        error.PBKDFD2 => "ERR_POSTGRES_AUTHENTICATION_FAILED_PBKDF2",
        error.SASL_SIGNATURE_MISMATCH => "ERR_POSTGRES_SASL_SIGNATURE_MISMATCH",
        error.SASL_SIGNATURE_INVALID_BASE64 => "ERR_POSTGRES_SASL_SIGNATURE_INVALID_BASE64",
        error.TLSNotAvailable => "ERR_POSTGRES_TLS_NOT_AVAILABLE",
        error.TLSUpgradeFailed => "ERR_POSTGRES_TLS_UPGRADE_FAILED",
        error.UnexpectedMessage => "ERR_POSTGRES_UNEXPECTED_MESSAGE",
        error.UNKNOWN_AUTHENTICATION_METHOD => "ERR_POSTGRES_UNKNOWN_AUTHENTICATION_METHOD",
        error.UNSUPPORTED_AUTHENTICATION_METHOD => "ERR_POSTGRES_UNSUPPORTED_AUTHENTICATION_METHOD",
        error.UnsupportedByteaFormat => "ERR_POSTGRES_UNSUPPORTED_BYTEA_FORMAT",
        error.UnsupportedArrayFormat => "ERR_POSTGRES_UNSUPPORTED_ARRAY_FORMAT",
        error.UnsupportedIntegerSize => "ERR_POSTGRES_UNSUPPORTED_INTEGER_SIZE",
        error.UnsupportedNumericFormat => "ERR_POSTGRES_UNSUPPORTED_NUMERIC_FORMAT",
        error.UnknownFormatCode => "ERR_POSTGRES_UNKNOWN_FORMAT_CODE",
        error.TooManyParameters,
        error.JSError,
        error.JSTerminated,
        error.OutOfMemory,
        error.ShortRead,
        => unreachable,
    };

    return .{
        .message = (message orelse std.fmt.bufPrint(message_buffer, "Failed to bind query: {s}", .{@errorName(err)})) catch "Failed to bind query",
        .options = .{ .code = code },
    };
}

const std = @import("std");
