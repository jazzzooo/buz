pub const domain = @import("./webcore.zig");

pub const prompt = domain.prompt;
pub const ByteListPool = domain.ByteListPool;
pub const Crypto = domain.Crypto;
pub const EncodingLabel = domain.EncodingLabel;
pub const TextEncoder = domain.TextEncoder;
pub const encoding = domain.encoding;
pub const EncodingBindings = domain.EncodingBindings;
pub const S3StatModule = domain.S3StatModule;
pub const S3Stat = domain.S3Stat;
pub const ScriptExecutionContext = domain.ScriptExecutionContext;
pub const PathOrFileDescriptor = domain.PathOrFileDescriptor;
pub const DrainResult = domain.DrainResult;
pub const Lifetime = domain.Lifetime;

pub const JSSinkBindings = @import("./webcore/JSSinkBindingsEngine.zig");
pub const DOMExceptionCode = @import("../jsc/JSErrorCode.zig").DOMExceptionCode;
pub const AbortSignal = @import("../jsc/AbortSignal.zig").AbortSignal;
pub const AutoFlusher = @import("../event_loop/AutoFlusher.zig");
pub const AutoFlusherEngine = @import("../event_loop/AutoFlusherEngine.zig");
pub const FormDataEngine = @import("./webcore/FormDataEngine.zig");
pub const Fetch = @import("./webcore/fetch.zig");
pub const Response = @import("./webcore/Response.zig");
pub const ResponseEngine = @import("./webcore/ResponseEngine.zig");
pub const BakeResponse = @import("./webcore/BakeResponse.zig");
pub const TextDecoder = @import("./webcore/TextDecoder.zig");
pub const TextEncoderStreamEncoder = @import("./webcore/TextEncoderStreamEncoder.zig");
pub const ReadableStream = @import("./webcore/ReadableStream.zig");
pub const Blob = @import("./webcore/Blob.zig");
pub const ResumableSinkModule = @import("./webcore/ResumableSinkEngine.zig");
pub const ResumableFetchSink = ResumableSinkModule.ResumableFetchSink;
pub const ResumableS3UploadSink = ResumableSinkModule.ResumableS3UploadSink;
pub const ResumableSinkBackpressure = ResumableSinkModule.ResumableSinkBackpressure;
pub const S3ClientModule = @import("./webcore/S3Client.zig");
pub const S3Client = S3ClientModule.S3Client;
pub const S3ClientEngine = @import("./webcore/S3ClientEngine.zig");
pub const S3StreamEngine = @import("./webcore/s3/ClientStreamEngine.zig");
pub const S3ErrorEngine = @import("./webcore/s3/ErrorEngine.zig");
pub const Request = @import("./webcore/Request.zig");
pub const RequestEngine = @import("./webcore/RequestEngine.zig");
pub const Body = @import("./webcore/Body.zig");
pub const BodyEngine = @import("./webcore/BodyEngine.zig");
pub const CookieMapEngine = @import("./webcore/CookieMapEngine.zig");
pub const CookieMap = CookieMapEngine.CookieMap;
pub const ObjectURLRegistry = @import("./webcore/ObjectURLRegistryEngine.zig");
pub const Sink = @import("./webcore/Sink.zig");
pub const FileSink = @import("./webcore/FileSink.zig");
pub const FetchHeaders = @import("../jsc/FetchHeaders.zig").FetchHeaders;
pub const ByteBlobLoader = @import("./webcore/ByteBlobLoaderEngine.zig");
pub const ByteStream = @import("./webcore/ByteStream.zig");
pub const FileReader = @import("./webcore/FileReader.zig");
pub const FileReaderEngine = @import("./webcore/FileReaderEngine.zig");

pub const streams = @import("./webcore/streams.zig");
pub const NetworkSink = streams.NetworkSink;
pub const HTTPResponseSink = streams.HTTPResponseSink;
pub const HTTPSResponseSink = streams.HTTPSResponseSink;
pub const H3ResponseSink = streams.H3ResponseSink;
pub const HTTPServerWritable = streams.HTTPServerWritable;

pub const Pipe = @import("./webcore/BytePipe.zig");

pub const WebSocketHTTPClient = @import("../http_jsc/websocket_client/WebSocketUpgradeClientEngine.zig").NewHTTPUpgradeClient(false);
pub const WebSocketHTTPSClient = @import("../http_jsc/websocket_client/WebSocketUpgradeClientEngine.zig").NewHTTPUpgradeClient(true);
pub const WebSocketClient = @import("../http_jsc/WebSocketClientEngine.zig").NewWebSocketClient(false);
pub const WebSocketClientTLS = @import("../http_jsc/WebSocketClientEngine.zig").NewWebSocketClient(true);
pub const WebSocketProxyTunnel = @import("../http_jsc/websocket_client/WebSocketProxyTunnelEngine.zig");

comptime {
    WebSocketClient.exportAll();
    WebSocketClientTLS.exportAll();
    WebSocketHTTPClient.exportAll();
    WebSocketHTTPSClient.exportAll();
}
