// When we start the request we will buffer data until partSize is reached or the last chunk is received.
// If the buffer is smaller than partSize, it will be sent as a single request. Otherwise, a multipart upload will be initiated.
// Single requests retain the upload until their callbacks return, including requests that finish after cancellation.
// When sending a multipart upload, if there is space in the queue, the part is enqueued, and the request starts immediately.
// If the queue is full, it waits to be drained before starting a new part request.
// Each part maintains a reference to MultiPartUpload until completion.
// If a part is canceled or fails early, the allocated slice is freed, and the reference is removed. If a part completes successfully, an etag is received, the allocated slice is deallocated, and the etag is appended to multipart_etags. If a part request fails, it retries until the maximum retry count is reached. If it still fails, MultiPartUpload is marked as failed and its reference is removed.
// If all parts succeed, a complete request is sent.
// If any part fails, a rollback request deletes the uploaded parts. Rollback and commit requests do not increase the reference count of MultiPartUpload, as they are the final step. Once commit or rollback finishes, the reference count is decremented, and MultiPartUpload is freed. These requests retry up to the maximum retry count on a best-effort basis.

//                Start Upload
//                       │
//                       ▼
//               Buffer Incoming Data
//                       │
//                       │
//          ┌────────────┴────────────────┐
//          │                             │
//          ▼                             ▼
// Buffer < PartSize             Buffer >= PartSize
//  and is Last Chunk                     │
//          │                             │
//          │                             │
//          │                             │
//          │                             │
//          │                             ▼
//          │                  Start Multipart Upload
//          │                             │
//          │                  Initialize Parts Queue
//          │                             │
//          │                   Process Upload Parts
//          │                             │
//          │                  ┌──────────┴──────────┐
//          │                  │                     │
//          │                  ▼                     ▼
//          │             Queue Has Space       Queue Full
//          │                  │                     │
//          │                  │                     ▼
//          │                  │              Wait for Queue
//          │                  │                     │
//          │                  └──────────┬──────────┘
//          │                             │
//          │                             ▼
//          │                     Start Part Upload
//          │               (Reference MultiPartUpload)
//          │                             │
//          │                  ┌─────────┼─────────┐
//          │                  │         │         │
//          │                  ▼         ▼         ▼
//          │               Part      Success   Failure
//          │             Canceled       │         │
//          │                  │         │     Retry Part
//          │                  │         │         │
//          │               Free       Free    Max Retries?
//          │               Slice      Slice    │        │
//          │                  │         │      No       Yes
//          │               Deref    Add eTag   │        │
//          │                MPU    to Array    │    Fail MPU
//          │                  │         │      │        │
//          │                  │         │      │    Deref MPU
//          │                  └─────────┼──────┘        │
//          │                            │               │
//          │                            ▼               │
//          │                   All Parts Complete?      │
//          │                            │               │
//          │                    ┌───────┴───────┐       │
//          │                    │               │       │
//          │                    ▼               ▼       │
//          │               All Success     Some Failed  │
//          │                    │               │       │
//          │                    ▼               ▼       │
//          │              Send Commit     Send Rollback │
//          │             (No Ref Inc)    (No Ref Inc)   │
//          │                    │               │       │
//          │                    └───────┬───────┘       │
//          │                            │               │
//          │                            ▼               │
//          │                     Retry if Failed        │
//          │                    (Best Effort Only)      │
//          │                            │               │
//          │                            ▼               │
//          │                     Deref Final MPU        │
//          │                            │               │
//          ▼                            │               │
//  Single Upload Request                │               │
//          │                            │               │
//          └────────────────────────────┴───────────────┘
//                         │
//                         ▼
//                        End
pub fn MultiPartUpload(comptime Scheduler: type) type {
    return struct {
        const OneMiB: usize = MultiPartUploadOptions.OneMiB;
        const MAX_SINGLE_UPLOAD_SIZE: usize = MultiPartUploadOptions.MAX_SINGLE_UPLOAD_SIZE; // we limit to 5 GiB
        const MIN_SINGLE_UPLOAD_SIZE: usize = MultiPartUploadOptions.MIN_SINGLE_UPLOAD_SIZE;
        const DefaultPartSize = MultiPartUploadOptions.DefaultPartSize;
        const MAX_QUEUE_SIZE = MultiPartUploadOptions.MAX_QUEUE_SIZE;
        const AWS = S3Credentials;
        queue: ?[]UploadPart = null,
        available: std.bit_set.Static(MAX_QUEUE_SIZE) = .full,

        currentPartNumber: u16 = 1,
        unreported_flushed_bytes: u64 = 0,
        ref_count: RefCount,
        ended: bool = false,
        activated: bool = false,

        options: MultiPartUploadOptions = .{},
        acl: ?ACL = null,
        storage_class: ?Storageclass = null,
        request_payer: bool = false,
        credentials: *S3Credentials,
        poll_ref: bun.Async.KeepAlive = bun.Async.KeepAlive.init(),
        scheduler: Scheduler,

        buffered: bun.io.StreamBuffer = .{},

        path: []const u8,
        proxy: []const u8,
        metadata: []u8,
        content_type: ?[]const u8 = null,
        content_disposition: ?[]const u8 = null,
        content_encoding: ?[]const u8 = null,
        upload_id: []const u8 = "",
        uploadid_buffer: bun.MutableString = .{ .allocator = bun.default_allocator, .list = .empty },

        multipart_etags: std.ArrayListUnmanaged(UploadPart.UploadPartResult) = .empty,
        multipart_upload_list: bun.ByteList = .{},

        state: enum {
            wait_stream_check,
            not_started,
            multipart_started,
            multipart_completed,
            singlefile_started,
            finished,
        } = .not_started,

        callback: *const fn (S3SimpleRequest.S3UploadResult, CallbackContext) void,
        onWritable: ?*const fn (task: *Self, ctx: CallbackContext, flushed: u64) void = null,
        callback_context: CallbackContext,

        const Self = @This();
        pub const CallbackContext = bun.bindgen.NativeCallbackContext(.vm);
        const RefCount = bun.ptr.RefCount(Self, "ref_count", deinit, .{});
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        const log = bun.Output.scoped(.S3MultiPartUpload, .hidden);

        pub const CreateOptions = struct {
            options: MultiPartUploadOptions,
            callback: *const fn (S3SimpleRequest.S3UploadResult, CallbackContext) void,
            callback_context: CallbackContext,
            on_writable: ?*const fn (*Self, CallbackContext, u64) void = null,
            proxy: ?[]const u8 = null,
            content_type: ?[]const u8 = null,
            content_disposition: ?[]const u8 = null,
            content_encoding: ?[]const u8 = null,
            acl: ?ACL = null,
            storage_class: ?Storageclass = null,
            request_payer: bool = false,
            wait_for_stream: bool = false,
        };

        pub fn create(credentials: *S3Credentials, path: []const u8, scheduler: Scheduler, options: CreateOptions) bun.OOM!*Self {
            const strings_to_copy = [_][]const u8{
                path,
                options.proxy orelse "",
                options.content_type orelse "",
                options.content_disposition orelse "",
                options.content_encoding orelse "",
            };
            var length: usize = 0;
            for (strings_to_copy) |value| {
                length = std.math.add(usize, length, value.len) catch return error.OutOfMemory;
            }
            const metadata = try bun.default_allocator.alloc(u8, length);
            errdefer bun.default_allocator.free(metadata);
            const this = try bun.default_allocator.create(Self);
            var remaining = metadata;
            this.* = .{
                .ref_count = .init(),
                .credentials = credentials,
                .scheduler = scheduler,
                .metadata = metadata,
                .path = copyMetadata(&remaining, path),
                .proxy = copyMetadata(&remaining, options.proxy orelse ""),
                .content_type = if (options.content_type) |value| copyMetadata(&remaining, value) else null,
                .content_disposition = if (options.content_disposition) |value| copyMetadata(&remaining, value) else null,
                .content_encoding = if (options.content_encoding) |value| copyMetadata(&remaining, value) else null,
                .options = options.options,
                .callback = options.callback,
                .callback_context = options.callback_context,
                .onWritable = options.on_writable,
                .acl = options.acl,
                .storage_class = options.storage_class,
                .request_payer = options.request_payer,
                .state = if (options.wait_for_stream) .wait_stream_check else .not_started,
            };
            bun.assert(remaining.len == 0);
            credentials.ref();
            return this;
        }

        fn copyMetadata(remaining: *[]u8, value: []const u8) []const u8 {
            const copied = remaining.*[0..value.len];
            @memcpy(copied, value);
            remaining.* = remaining.*[value.len..];
            return copied;
        }

        pub fn activate(this: *Self) void {
            bun.assert(!this.activated);
            this.activated = true;
            this.ref();
            this.scheduler.ref(&this.poll_ref);
        }

        pub const UploadPart = struct {
            data: []const u8,
            ctx: *Self,
            allocated_size: usize,
            state: enum(u8) {
                not_assigned = 0,
                pending = 1,
                started = 2,
                completed = 3,
                canceled = 4,
            },
            partNumber: u16, // max is 10,000
            retry: u8, // auto retry, decrement until 0 and fail after this
            index: u8,

            pub const UploadPartResult = struct {
                number: u16,
                etag: []const u8,
            };

            fn sortEtags(_: *Self, a: UploadPart.UploadPartResult, b: UploadPart.UploadPartResult) bool {
                return a.number < b.number;
            }

            fn freeAllocatedSlice(this: *@This()) void {
                const slice = this.allocatedSlice();
                if (slice.len > 0) {
                    bun.default_allocator.free(slice);
                }
                this.data = "";
                this.allocated_size = 0;
            }

            fn allocatedSlice(this: *@This()) []const u8 {
                if (this.allocated_size > 0) {
                    return this.data.ptr[0..this.allocated_size];
                }
                return "";
            }

            pub fn onPartResponse(result: S3SimpleRequest.S3PartResult, opaque_this: CallbackContext) void {
                const this = opaque_this.get(*@This());
                if (this.state == .canceled or this.ctx.state == .finished) {
                    log("onPartResponse {} canceled", .{this.partNumber});
                    this.freeAllocatedSlice();
                    this.ctx.deref();
                    return;
                }

                this.state = .completed;

                switch (result) {
                    .out_of_memory => {
                        this.state = .not_assigned;
                        this.freeAllocatedSlice();
                        defer this.ctx.deref();
                        this.ctx.failOutOfMemory();
                    },
                    .failure => |err| {
                        if (this.retry > 0) {
                            log("onPartResponse {} retry", .{this.partNumber});
                            this.retry -= 1;
                            // retry failed
                            this.perform();
                            return;
                        } else {
                            this.state = .not_assigned;
                            log("onPartResponse {} failed", .{this.partNumber});
                            this.freeAllocatedSlice();
                            defer this.ctx.deref();
                            return this.ctx.fail(err);
                        }
                    },
                    .etag => |etag| {
                        log("onPartResponse {} success", .{this.partNumber});
                        const sent = this.data.len;
                        this.freeAllocatedSlice();
                        this.state = .not_assigned;
                        defer this.ctx.deref();
                        const owned_etag = bun.default_allocator.dupe(u8, etag) catch {
                            this.ctx.failOutOfMemory();
                            return;
                        };
                        this.ctx.multipart_etags.append(bun.default_allocator, .{
                            .number = this.partNumber,
                            .etag = owned_etag,
                        }) catch {
                            bun.default_allocator.free(owned_etag);
                            this.ctx.failOutOfMemory();
                            return;
                        };
                        // mark as available
                        this.ctx.available.set(this.index);
                        // drain more
                        this.ctx.drainEnqueuedParts(sent);
                    },
                }
            }

            fn perform(this: *@This()) void {
                const search_params = std.fmt.allocPrint(bun.default_allocator, "?partNumber={}&uploadId={s}&x-id=UploadPart", .{
                    this.partNumber,
                    this.ctx.upload_id,
                }) catch {
                    this.state = .not_assigned;
                    this.freeAllocatedSlice();
                    defer this.ctx.deref();
                    this.ctx.failOutOfMemory();
                    return;
                };
                defer bun.default_allocator.free(search_params);
                S3SimpleRequest.executeSimpleS3Request(Scheduler, this.ctx.credentials, .{
                    .path = this.ctx.path,
                    .method = .PUT,
                    .proxy_url = this.ctx.proxyUrl(),
                    .body = this.data,
                    .search_params = search_params,
                    .request_payer = this.ctx.request_payer,
                }, .{ .part = onPartResponse }, .init(this));
            }
            pub fn start(this: *@This()) void {
                if (this.state != .pending or this.ctx.state != .multipart_completed) return;
                this.ctx.ref();
                this.state = .started;
                this.perform();
            }
            pub fn cancel(this: *@This()) void {
                const state = this.state;
                this.state = .canceled;

                switch (state) {
                    .pending => {
                        this.freeAllocatedSlice();
                    },
                    // if is not pending we will free later or is already freed
                    else => {},
                }
            }
        };

        fn deinit(this: *@This()) void {
            log("deinit", .{});
            if (this.queue) |queue| {
                this.queue = null;
                bun.default_allocator.free(queue);
            }
            this.scheduler.unref(&this.poll_ref);
            bun.default_allocator.free(this.metadata);
            this.buffered.deinit();
            this.credentials.deref();
            this.uploadid_buffer.deinit();
            for (this.multipart_etags.items) |tag| {
                bun.default_allocator.free(tag.etag);
            }
            if (this.multipart_etags.capacity > 0)
                this.multipart_etags.deinit(bun.default_allocator);
            if (this.multipart_upload_list.cap > 0)
                this.multipart_upload_list.deinit(bun.default_allocator);
            bun.destroy(this);
        }

        pub fn singleSendUploadResponse(result: S3SimpleRequest.S3UploadResult, opaque_this: CallbackContext) void {
            const this = opaque_this.get(*@This());
            defer this.deref();
            if (this.state == .finished) return;
            switch (result) {
                .out_of_memory => this.failOutOfMemory(),
                .failure => |err| {
                    if (this.options.retry > 0) {
                        log("singleSendUploadResponse {} retry", .{this.options.retry});
                        this.options.retry -= 1;
                        this.sendSingleUpload();

                        return;
                    } else {
                        log("singleSendUploadResponse failed", .{});
                        return this.fail(err);
                    }
                },
                .success => {
                    log("singleSendUploadResponse success", .{});

                    if (this.onWritable) |callback| {
                        callback(this, this.callback_context, this.buffered.size());
                    }
                    this.done();
                },
            }
        }

        /// This is the only place we allocate the queue or the parts, this is responsible for the flow of parts and the max allowed concurrency
        fn getCreatePart(this: *@This(), chunk: []const u8, allocated_size: usize, needs_clone: bool) bun.OOM!?*UploadPart {
            const index = this.available.findFirstSet() orelse {
                // this means that the queue is full and we cannot flush it
                return null;
            };
            const queueSize = this.options.queueSize;
            if (index >= queueSize) {
                // ops too much concurrency wait more
                return null;
            }
            if (this.queue == null) {
                // queueSize will never change and is small (max 255)
                const queue = try bun.default_allocator.alloc(UploadPart, queueSize);
                // zero set just in case
                @memset(queue, UploadPart{
                    .data = "",
                    .allocated_size = 0,
                    .partNumber = 0,
                    .ctx = this,
                    .index = 0,
                    .retry = 0,
                    .state = .not_assigned,
                });
                this.queue = queue;
            }
            const data = if (needs_clone) try bun.default_allocator.dupe(u8, chunk) else chunk;
            const allocated_len = if (needs_clone) data.len else allocated_size;

            const queue_item = &this.queue.?[index];
            // always set all struct fields to avoid undefined behavior
            queue_item.* = .{
                .data = data,
                .allocated_size = allocated_len,
                .partNumber = this.currentPartNumber,
                .ctx = this,
                .index = @truncate(index),
                .retry = this.options.retry,
                .state = .pending,
            };
            this.available.unset(index);
            this.currentPartNumber += 1;
            return queue_item;
        }

        /// Drain the parts, this is responsible for starting the parts and processing the buffered data
        fn drainEnqueuedParts(this: *@This(), flushed: u64) void {
            if (this.state == .finished or this.state == .singlefile_started) {
                return;
            }
            this.unreported_flushed_bytes += flushed;
            // check pending to start or transformed buffered ones into tasks
            if (this.state == .multipart_completed) {
                if (this.queue) |queue| {
                    for (queue) |*part| {
                        if (part.state == .pending) {
                            // lets start the part request
                            part.start();
                        }
                    }
                }
            }
            const partSize = this.partSizeInBytes();
            if (this.ended or this.buffered.size() >= partSize) {
                this.processMultiPart(partSize) catch {
                    this.failOutOfMemory();
                    return;
                };
            }

            // empty queue
            if (this.isQueueEmpty()) {
                this.reportWritable();
                if (this.ended) {
                    // we are done and no more parts are running
                    this.done();
                }
            } else if (!this.hasBackpressure() and this.unreported_flushed_bytes > 0) {
                // we have more space in the queue, we can drain more
                this.reportWritable();
            }
        }
        fn reportWritable(this: *@This()) void {
            if (this.onWritable) |callback| {
                const flushed = this.unreported_flushed_bytes;
                this.unreported_flushed_bytes = 0;
                callback(this, this.callback_context, flushed);
            }
        }

        /// Finalize the upload with a failure
        pub fn fail(this: *@This(), _err: S3Error) void {
            log("fail {s}:{s}", .{ _err.code, _err.message });
            this.failResult(.{ .failure = _err });
        }

        pub fn failOutOfMemory(this: *Self) void {
            this.failResult(.out_of_memory);
        }

        fn failResult(this: *Self, result: S3SimpleRequest.S3UploadResult) void {
            bun.assert(result != .success);
            if (this.state == .finished) return;
            bun.assert(this.activated);
            this.ref();
            defer this.deref();
            const old_state = this.state;
            this.state = .finished;
            this.ended = true;
            if (this.queue) |queue| {
                for (queue) |*task| {
                    if (task.state != .not_assigned) {
                        task.cancel();
                    }
                }
            }
            this.callback(result, this.callback_context);
            if (old_state == .multipart_completed) {
                this.rollbackMultiPartRequest();
            } else {
                this.deref();
            }
        }
        /// Finalize successful the upload
        fn done(this: *@This()) void {
            if (this.state == .multipart_completed) {
                std.sort.block(UploadPart.UploadPartResult, this.multipart_etags.items, this, UploadPart.sortEtags);
                this.buildCommitBody() catch {
                    this.failOutOfMemory();
                    return;
                };
                for (this.multipart_etags.items) |tag| {
                    bun.default_allocator.free(tag.etag);
                }
                this.multipart_etags.deinit(bun.default_allocator);
                this.multipart_etags = .empty;
                this.state = .finished;
                this.commitMultiPartRequest();
            } else if (this.state == .singlefile_started) {
                this.state = .finished;
                // single file upload no need to commit
                defer this.deref();
                this.callback(.{ .success = {} }, this.callback_context);
            }
        }

        fn buildCommitBody(this: *Self) bun.OOM!void {
            try this.multipart_upload_list.appendSlice(
                bun.default_allocator,
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">",
            );
            for (this.multipart_etags.items) |tag| {
                try this.multipart_upload_list.appendFmt(bun.default_allocator, "<Part><PartNumber>{}</PartNumber><ETag>{s}</ETag></Part>", .{ tag.number, tag.etag });
            }
            try this.multipart_upload_list.appendSlice(bun.default_allocator, "</CompleteMultipartUpload>");
        }

        /// Result of the Multipart request, after this we can start draining the parts
        pub fn startMultiPartRequestResult(result: S3SimpleRequest.S3DownloadResult, opaque_this: CallbackContext) void {
            const this = opaque_this.get(*@This());
            defer this.deref();
            if (this.state == .finished) {
                if (result == .success) {
                    var body = result.success.body;
                    body.deinit();
                }
                return;
            }
            switch (result) {
                .out_of_memory => this.failOutOfMemory(),
                .failure => |err| {
                    log("startMultiPartRequestResult {s} failed {s}: {s}", .{ this.path, err.message, err.message });
                    this.fail(err);
                },
                .success => |response| {
                    const slice = response.body.list.items;
                    this.uploadid_buffer = result.success.body;

                    if (strings.indexOf(slice, "<UploadId>")) |start| {
                        if (strings.indexOf(slice, "</UploadId>")) |end| {
                            this.upload_id = slice[start + 10 .. end];
                        }
                    }
                    if (this.upload_id.len == 0) {
                        // Unknown type of response error from AWS
                        log("startMultiPartRequestResult {s} failed invalid id", .{this.path});
                        this.fail(.{
                            .code = "UnknownError",
                            .message = "Failed to initiate multipart upload",
                        });
                        return;
                    }
                    log("startMultiPartRequestResult {s} success id: {s}", .{ this.path, this.upload_id });
                    this.state = .multipart_completed;
                    // start draining the parts
                    this.drainEnqueuedParts(0);
                },
                // this is "unreachable" but we cover in case AWS returns 404
                .not_found => this.fail(.{
                    .code = "UnknownError",
                    .message = "Failed to initiate multipart upload",
                }),
            }
        }

        /// We do a best effort to commit the multipart upload, if it fails we will retry, if it still fails we will fail the upload
        pub fn onCommitMultiPartRequest(result: S3SimpleRequest.S3CommitResult, opaque_this: CallbackContext) void {
            const this = opaque_this.get(*@This());
            log("onCommitMultiPartRequest {s}", .{this.upload_id});

            switch (result) {
                .out_of_memory => {
                    defer this.deref();
                    this.state = .finished;
                    this.callback(.out_of_memory, this.callback_context);
                },
                .failure => |err| {
                    if (this.options.retry > 0) {
                        this.options.retry -= 1;
                        // retry commit
                        this.commitMultiPartRequest();
                        return;
                    }
                    defer this.deref();
                    this.state = .finished;
                    this.callback(.{ .failure = err }, this.callback_context);
                },
                .success => {
                    defer this.deref();
                    this.state = .finished;
                    this.callback(.{ .success = {} }, this.callback_context);
                },
            }
        }
        /// We do a best effort to rollback the multipart upload, if it fails we will retry, if it still we just deinit the upload
        pub fn onRollbackMultiPartRequest(result: S3SimpleRequest.S3UploadResult, opaque_this: CallbackContext) void {
            const this = opaque_this.get(*@This());
            log("onRollbackMultiPartRequest {s}", .{this.upload_id});
            switch (result) {
                .out_of_memory => this.deref(),
                .failure => {
                    if (this.options.retry > 0) {
                        this.options.retry -= 1;
                        // retry rollback
                        this.rollbackMultiPartRequest();
                        return;
                    }
                    this.deref();
                },
                .success => {
                    this.deref();
                },
            }
        }

        fn commitMultiPartRequest(this: *@This()) void {
            log("commitMultiPartRequest {s}", .{this.upload_id});
            const searchParams = std.fmt.allocPrint(bun.default_allocator, "?uploadId={s}", .{
                this.upload_id,
            }) catch {
                defer this.deref();
                this.callback(.out_of_memory, this.callback_context);
                return;
            };
            defer bun.default_allocator.free(searchParams);

            S3SimpleRequest.executeSimpleS3Request(Scheduler, this.credentials, .{
                .path = this.path,
                .method = .POST,
                .proxy_url = this.proxyUrl(),
                .body = this.multipart_upload_list.slice(),
                .search_params = searchParams,
                .request_payer = this.request_payer,
            }, .{ .commit = onCommitMultiPartRequest }, .init(this));
        }
        fn rollbackMultiPartRequest(this: *@This()) void {
            log("rollbackMultiPartRequest {s}", .{this.upload_id});
            const search_params = std.fmt.allocPrint(bun.default_allocator, "?uploadId={s}", .{
                this.upload_id,
            }) catch {
                this.deref();
                return;
            };
            defer bun.default_allocator.free(search_params);

            S3SimpleRequest.executeSimpleS3Request(Scheduler, this.credentials, .{
                .path = this.path,
                .method = .DELETE,
                .proxy_url = this.proxyUrl(),
                .body = "",
                .search_params = search_params,
                .request_payer = this.request_payer,
            }, .{ .upload = onRollbackMultiPartRequest }, .init(this));
        }
        fn enqueuePart(this: *@This(), chunk: []const u8, allocated_size: usize, needs_clone: bool) bun.OOM!bool {
            const part = try this.getCreatePart(chunk, allocated_size, needs_clone) orelse return false;

            if (this.state == .not_started) {
                // will auto start later
                this.state = .multipart_started;
                this.ref();
                S3SimpleRequest.executeSimpleS3Request(Scheduler, this.credentials, .{
                    .path = this.path,
                    .method = .POST,
                    .proxy_url = this.proxyUrl(),
                    .body = "",
                    .search_params = "?uploads=",
                    .content_type = this.content_type,
                    .content_disposition = this.content_disposition,
                    .content_encoding = this.content_encoding,
                    .acl = this.acl,
                    .storage_class = this.storage_class,
                    .request_payer = this.request_payer,
                }, .{ .download = startMultiPartRequestResult }, .init(this));
            } else if (this.state == .multipart_completed) {
                part.start();
            }
            return true;
        }

        fn processMultiPart(this: *@This(), part_size: usize) bun.OOM!void {
            log("processMultiPart {s} {d}", .{ this.path, part_size });
            if (this.buffered.isEmpty() and this.isQueueEmpty() and this.ended) {
                // no more data to send and we are done
                this.done();
                return;
            }
            // need to split in multiple parts because of the size
            defer if (this.buffered.isEmpty()) {
                this.buffered.reset();
            };

            while (this.buffered.isNotEmpty()) {
                const len = @min(part_size, this.buffered.size());
                if (len < part_size and !this.ended) {
                    log("processMultiPart {s} {d} slice too small", .{ this.path, len });
                    //slice is too small, we need to wait for more data
                    break;
                }
                // if is one big chunk we can pass ownership and avoid dupe
                if (this.buffered.cursor == 0 and this.buffered.size() == len) {
                    // we need to know the allocated size to free the memory later
                    const allocated_size = this.buffered.memoryCost();
                    const slice = this.buffered.slice();

                    // we dont care about the result because we are sending everything
                    if (try this.enqueuePart(slice, allocated_size, false)) {
                        log("processMultiPart {s} {d} full buffer enqueued", .{ this.path, slice.len });

                        // queue is not full, we can clear the buffer part now owns the data
                        // if its full we will retry later
                        this.buffered = .{};
                        return;
                    }
                    log("processMultiPart {s} {d} queue full", .{ this.path, slice.len });

                    return;
                }

                const slice = this.buffered.slice()[0..len];
                // allocated size is the slice len because we dupe the buffer
                if (try this.enqueuePart(slice, slice.len, true)) {
                    log("processMultiPart {s} {d} slice enqueued", .{ this.path, slice.len });
                    // queue is not full, we can set the offset
                    this.buffered.wrote(len);
                } else {
                    log("processMultiPart {s} {d} queue full", .{ this.path, slice.len });
                    // queue is full stop enqueue and retry later
                    break;
                }
            }
        }

        pub fn proxyUrl(this: *@This()) ?[]const u8 {
            return this.proxy;
        }
        fn processBuffered(this: *@This(), part_size: usize) bun.OOM!void {
            if (this.ended and this.buffered.size() < this.partSizeInBytes() and this.state == .not_started) {
                log("processBuffered {s} singlefile_started", .{this.path});
                this.state = .singlefile_started;
                this.sendSingleUpload();
            } else {
                // we need to split
                try this.processMultiPart(part_size);
            }
        }

        fn sendSingleUpload(this: *Self) void {
            this.ref();
            S3SimpleRequest.executeSimpleS3Request(Scheduler, this.credentials, .{
                .path = this.path,
                .method = .PUT,
                .proxy_url = this.proxyUrl(),
                .body = this.buffered.slice(),
                .content_type = this.content_type,
                .content_disposition = this.content_disposition,
                .content_encoding = this.content_encoding,
                .acl = this.acl,
                .storage_class = this.storage_class,
                .request_payer = this.request_payer,
            }, .{ .upload = singleSendUploadResponse }, .init(this));
        }

        pub fn partSizeInBytes(this: *@This()) usize {
            return this.options.partSize;
        }

        pub fn continueStream(this: *@This()) bun.OOM!void {
            this.ref();
            defer this.deref();
            if (this.state == .wait_stream_check) {
                this.state = .not_started;
                if (this.ended or this.buffered.size() >= this.partSizeInBytes()) {
                    try this.processBuffered(this.partSizeInBytes());
                }
            }
        }

        pub fn hasBackpressure(this: *@This()) bool {
            // if we dont have any space in the queue, we have backpressure
            // since we are not allowed to send more data
            const index = this.available.findFirstSet() orelse return true;
            return index >= this.options.queueSize;
        }

        pub fn isQueueEmpty(this: *@This()) bool {
            return this.available.eql(.full);
        }

        pub const WriteEncoding = enum {
            bytes,
            latin1,
            utf16,
        };

        fn write(this: *@This(), chunk: []const u8, is_last: bool, comptime encoding: WriteEncoding) bun.OOM!ResumableSinkBackpressure {
            if (this.ended) return .done; // no backpressure since we are done
            // we may call done inside processBuffered so we ensure that we keep a ref until we are done
            this.ref();
            defer this.deref();
            if (this.state == .wait_stream_check) {
                // Native input can finish during attachment, before its callback owner has stored the sink.
                switch (encoding) {
                    .bytes => try this.buffered.write(chunk),
                    .latin1 => try this.buffered.writeLatin1(chunk, true),
                    .utf16 => try this.buffered.writeUTF16(@alignCast(std.mem.bytesAsSlice(u16, chunk))),
                }
                this.ended = is_last;
                return if (this.hasBackpressure()) .backpressure else .want_more;
            }
            if (is_last) {
                this.ended = true;
                if (chunk.len > 0) {
                    switch (encoding) {
                        .bytes => try this.buffered.write(chunk),
                        .latin1 => try this.buffered.writeLatin1(chunk, true),
                        .utf16 => try this.buffered.writeUTF16(@alignCast(std.mem.bytesAsSlice(u16, chunk))),
                    }
                }
                try this.processBuffered(this.partSizeInBytes());
            } else {
                // still have more data and receive empty, nothing todo here
                if (chunk.len == 0) return if (this.hasBackpressure()) .backpressure else .want_more;
                switch (encoding) {
                    .bytes => try this.buffered.write(chunk),
                    .latin1 => try this.buffered.writeLatin1(chunk, true),
                    .utf16 => try this.buffered.writeUTF16(@alignCast(std.mem.bytesAsSlice(u16, chunk))),
                }
                const partSize = this.partSizeInBytes();
                if (this.buffered.size() >= partSize) {
                    // send the part we have enough data
                    try this.processBuffered(partSize);
                }

                // wait for more
            }
            return if (this.hasBackpressure()) .backpressure else .want_more;
        }

        pub fn writeLatin1(this: *@This(), chunk: []const u8, is_last: bool) bun.OOM!ResumableSinkBackpressure {
            return try this.write(chunk, is_last, .latin1);
        }

        pub fn writeUTF16(this: *@This(), chunk: []const u8, is_last: bool) bun.OOM!ResumableSinkBackpressure {
            return try this.write(chunk, is_last, .utf16);
        }

        pub fn writeBytes(this: *@This(), chunk: []const u8, is_last: bool) bun.OOM!ResumableSinkBackpressure {
            return try this.write(chunk, is_last, .bytes);
        }
    };
}

const std = @import("std");
const ACL = @import("../../../s3_signing/acl.zig").ACL;
const MultiPartUploadOptions = @import("../../../s3_signing/multipart_options.zig").MultiPartUploadOptions;
const S3Credentials = @import("../../../s3_signing/credentials.zig").S3Credentials;
const S3Error = @import("../../../s3_signing/error.zig").S3Error;
const Storageclass = @import("../../../s3_signing/storage_class.zig").StorageClass;

const S3SimpleRequest = @import("./simple_request.zig");
const bun = @import("bun");
const strings = bun.strings;
const ResumableSinkBackpressure = @import("../ResumableSinkBackpressure.zig").ResumableSinkBackpressure;
