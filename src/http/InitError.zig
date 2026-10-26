pub const InitError = error{
    OutOfMemory,
    FailedToOpenSocket,
    LoadCAFile,
    InvalidCAFile,
    InvalidCA,
};
