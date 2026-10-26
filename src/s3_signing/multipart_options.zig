pub const MultiPartUploadOptions = struct {
    pub const OneMiB: usize = 1048576;
    pub const MAX_SINGLE_UPLOAD_SIZE: usize = 5120 * OneMiB;
    pub const MIN_SINGLE_UPLOAD_SIZE: usize = 5 * OneMiB;
    pub const DefaultPartSize = MIN_SINGLE_UPLOAD_SIZE;
    pub const MAX_QUEUE_SIZE = 64;

    queueSize: u8 = 5,
    partSize: u64 = DefaultPartSize,
    retry: u8 = 3,
};
