pub const Request = struct {
    store: *Store,
    credentials: *const S3.S3Credentials,
    proxy: ?[]const u8,
    request_payer: bool,
};

pub const StatKind = enum { exists, size, stat };

pub fn StatAcceptor(comptime kind: StatKind) type {
    return switch (kind) {
        .exists => S3.S3ExistsAcceptor,
        .size => S3.S3SizeAcceptor,
        .stat => S3.S3StatAcceptor,
    };
}

pub fn stat(comptime kind: StatKind, request: Request, acceptor: *StatAcceptor(kind)) bun.OOM!void {
    const Task = struct {
        store: bun.bindgen.RefNative(Store, .any),
        acceptor: StatAcceptor(kind),

        fn resolve(result: S3.S3StatResult, context: S3.CallbackContext) void {
            const this = context.get(*@This());
            defer {
                this.acceptor.release();
                this.store.deinit();
                bun.destroy(this);
            }
            switch (result) {
                .out_of_memory => this.acceptor.outOfMemory(),
                .not_found => |err| {
                    if (comptime kind == .exists) {
                        this.acceptor.resolve(false);
                    } else {
                        this.acceptor.rejectError(err, this.store.get().data.s3.path());
                    }
                },
                .failure => |err| this.acceptor.rejectError(err, this.store.get().data.s3.path()),
                .success => |value| switch (kind) {
                    .exists => this.acceptor.resolve(true),
                    .size => this.acceptor.resolve(value.size),
                    .stat => {
                        const payload = S3.OwnedS3Stat.init(value.size, value.etag, value.contentType, value.lastModified) catch {
                            this.acceptor.outOfMemory();
                            return;
                        };
                        this.acceptor.resolve(payload);
                    },
                },
            }
        }
    };
    const task = try bun.default_allocator.create(Task);
    task.* = .{ .store = .init(request.store), .acceptor = acceptor.take() };
    S3.stat(request.credentials, request.store.data.s3.path(), Task.resolve, .init(task), request.proxy, request.request_payer);
}

pub fn delete(request: Request, acceptor: *S3.S3VoidAcceptor) bun.OOM!void {
    const Task = struct {
        store: bun.bindgen.RefNative(Store, .any),
        acceptor: S3.S3VoidAcceptor,

        fn resolve(result: S3.S3DeleteResult, context: S3.CallbackContext) void {
            const this = context.get(*@This());
            defer {
                this.acceptor.release();
                this.store.deinit();
                bun.destroy(this);
            }
            switch (result) {
                .out_of_memory => this.acceptor.outOfMemory(),
                .success => this.acceptor.resolve({}),
                .not_found, .failure => |err| this.acceptor.rejectError(err, this.store.get().getPath()),
            }
        }
    };
    const task = try bun.default_allocator.create(Task);
    task.* = .{ .store = .init(request.store), .acceptor = acceptor.take() };
    S3.delete(request.credentials, request.store.data.s3.path(), Task.resolve, .init(task), request.proxy, request.request_payer);
}

pub fn list(request: Request, options: *S3.S3ListObjectsOptions, acceptor: *S3.S3ListAcceptor) bun.OOM!void {
    const Task = struct {
        store: bun.bindgen.RefNative(Store, .any),
        options: S3.S3ListObjectsOptions,
        acceptor: S3.S3ListAcceptor,

        fn resolve(result: S3.S3ListObjectsResult, context: S3.CallbackContext) void {
            const this = context.get(*@This());
            defer {
                this.acceptor.release();
                this.options.deinit();
                this.store.deinit();
                bun.destroy(this);
            }
            switch (result) {
                .out_of_memory => this.acceptor.outOfMemory(),
                .success => |body| this.acceptor.resolve(body),
                .not_found, .failure => |err| this.acceptor.rejectError(err, this.store.get().getPath()),
            }
        }
    };
    const task = try bun.default_allocator.create(Task);
    task.* = .{ .store = .init(request.store), .options = options.take(), .acceptor = acceptor.take() };
    S3.listObjects(request.credentials, task.options, Task.resolve, .init(task), request.proxy);
}

pub fn presign(path: []const u8, options: *const S3.S3CredentialsWithOptions, method: bun.http.Method, expires: usize) !S3.S3Credentials.SignResult {
    return options.credentials.signRequest(.{
        .path = path,
        .method = method,
        .acl = options.acl,
        .storage_class = options.storage_class,
        .request_payer = options.request_payer,
        .content_disposition = options.content_disposition,
        .content_type = options.content_type,
    }, false, .{ .expires = expires });
}

const bun = @import("bun");
const S3 = bun.S3;
const Store = @import("../blob/Store.zig");
