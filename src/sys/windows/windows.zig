//! Platform specific APIs for Windows
//!
//! If an API can be implemented on multiple platforms,
//! it does not belong in this namespace.

pub const ntdll = windows.ntdll;
pub const kernel32 = windows.kernel32;
pub const GetLastError = windows.GetLastError;

pub const PATH_MAX_WIDE = windows.PATH_MAX_WIDE;
pub const MAX_PATH = windows.MAX_PATH;
pub const WORD = windows.WORD;
pub const DWORD = windows.DWORD;
pub const SHORT = windows.SHORT;
pub const CHAR = windows.CHAR;
pub const BOOL = windows.BOOL;
pub const BOOLEAN = windows.BOOLEAN;
pub const LPVOID = windows.LPVOID;
pub const LPCVOID = windows.LPCVOID;
pub const LPWSTR = windows.LPWSTR;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPSTR = windows.LPSTR;
pub const WCHAR = windows.WCHAR;
pub const LPCSTR = windows.LPCSTR;
pub const PWSTR = windows.PWSTR;
pub const FALSE: BOOL = .FALSE;
pub const TRUE: BOOL = .TRUE;
pub const COORD = windows.COORD;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const FILE_BEGIN: DWORD = asDword(c.FILE_BEGIN);
pub const FILE_END: DWORD = asDword(c.FILE_END);
pub const FILE_CURRENT: DWORD = asDword(c.FILE_CURRENT);
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const ULONGLONG = windows.ULONGLONG;
pub const UINT = windows.UINT;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const UNICODE_STRING = windows.UNICODE_STRING;
pub const NTSTATUS = windows.NTSTATUS;
pub const WinsockError = enum(c_int) { _ };
pub const NT_SUCCESS = windows.NT_SUCCESS;
pub const STATUS_SUCCESS = windows.STATUS_SUCCESS;
pub const unexpectedStatus = windows.unexpectedStatus;
pub const RtlNtStatusToDosError = @import("../../windows_sys/externs.zig").RtlNtStatusToDosError;

pub fn getLastWinsockErrno() bun.sys.E {
    return SystemErrno.fromWinsock(@fromBackingInt(bun.c.WSAGetLastError())).toE();
}

pub const MOVEFILE_COPY_ALLOWED = 0x2;
pub const MOVEFILE_REPLACE_EXISTING = 0x1;
pub const MOVEFILE_WRITE_THROUGH = 0x8;
pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_BREAK_EVENT: DWORD = 1;
pub const CTRL_CLOSE_EVENT: DWORD = 2;
pub const FILETIME = windows.FILETIME;
pub const BY_HANDLE_FILE_INFORMATION = @import("../../windows_sys/externs.zig").BY_HANDLE_FILE_INFORMATION;

pub const DUPLICATE_SAME_ACCESS: DWORD = asDword(c.DUPLICATE_SAME_ACCESS);
pub const OBJECT_ATTRIBUTES = windows.OBJECT.ATTRIBUTES;
pub const IO_STATUS_BLOCK = windows.IO_STATUS_BLOCK;
pub const FILE_INFO_BY_HANDLE_CLASS = windows.FILE_INFO_BY_HANDLE_CLASS;
pub const FILE_SHARE_READ: DWORD = asDword(c.FILE_SHARE_READ);
pub const FILE_SHARE_WRITE: DWORD = asDword(c.FILE_SHARE_WRITE);
pub const FILE_SHARE_DELETE: DWORD = asDword(c.FILE_SHARE_DELETE);
pub const FILE_ATTRIBUTE_NORMAL: DWORD = asDword(c.FILE_ATTRIBUTE_NORMAL);
pub const FILE_ATTRIBUTE_READONLY: DWORD = asDword(c.FILE_ATTRIBUTE_READONLY);
pub const FILE_ATTRIBUTE_HIDDEN: DWORD = asDword(c.FILE_ATTRIBUTE_HIDDEN);
pub const FILE_ATTRIBUTE_SYSTEM: DWORD = asDword(c.FILE_ATTRIBUTE_SYSTEM);
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = asDword(c.FILE_ATTRIBUTE_DIRECTORY);
pub const FILE_ATTRIBUTE_ARCHIVE: DWORD = asDword(c.FILE_ATTRIBUTE_ARCHIVE);
pub const FILE_ATTRIBUTE_DEVICE: DWORD = asDword(c.FILE_ATTRIBUTE_DEVICE);
pub const FILE_ATTRIBUTE_TEMPORARY: DWORD = asDword(c.FILE_ATTRIBUTE_TEMPORARY);
pub const FILE_ATTRIBUTE_SPARSE_FILE: DWORD = asDword(c.FILE_ATTRIBUTE_SPARSE_FILE);
pub const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = asDword(c.FILE_ATTRIBUTE_REPARSE_POINT);
pub const FILE_ATTRIBUTE_COMPRESSED: DWORD = asDword(c.FILE_ATTRIBUTE_COMPRESSED);
pub const FILE_ATTRIBUTE_OFFLINE: DWORD = asDword(c.FILE_ATTRIBUTE_OFFLINE);
pub const FILE_ATTRIBUTE_NOT_CONTENT_INDEXED: DWORD = asDword(c.FILE_ATTRIBUTE_NOT_CONTENT_INDEXED);
pub const FILE_DIRECTORY_FILE: DWORD = asDword(c.FILE_DIRECTORY_FILE);
pub const FILE_NON_DIRECTORY_FILE: DWORD = asDword(c.FILE_NON_DIRECTORY_FILE);
pub const FILE_WRITE_THROUGH: DWORD = asDword(c.FILE_WRITE_THROUGH);
pub const FILE_SEQUENTIAL_ONLY: DWORD = asDword(c.FILE_SEQUENTIAL_ONLY);
pub const FILE_SYNCHRONOUS_IO_NONALERT: DWORD = asDword(c.FILE_SYNCHRONOUS_IO_NONALERT);
pub const FILE_OPEN_REPARSE_POINT: DWORD = asDword(c.FILE_OPEN_REPARSE_POINT);
pub const FILE_OPEN_FOR_BACKUP_INTENT: DWORD = asDword(c.FILE_OPEN_FOR_BACKUP_INTENT);
pub const FILE_DELETE_ON_CLOSE: DWORD = asDword(c.FILE_DELETE_ON_CLOSE);
pub const FILE_READ_ATTRIBUTES: DWORD = asDword(c.FILE_READ_ATTRIBUTES);
pub const FILE_READ_EA: DWORD = asDword(c.FILE_READ_EA);
pub const FILE_READ_DATA: DWORD = asDword(c.FILE_READ_DATA);
pub const FILE_WRITE_ATTRIBUTES: DWORD = asDword(c.FILE_WRITE_ATTRIBUTES);
pub const FILE_WRITE_DATA: DWORD = asDword(c.FILE_WRITE_DATA);
pub const FILE_APPEND_DATA: DWORD = asDword(c.FILE_APPEND_DATA);
pub const FILE_TRAVERSE: DWORD = asDword(c.FILE_TRAVERSE);
pub const FILE_LIST_DIRECTORY: DWORD = asDword(c.FILE_LIST_DIRECTORY);
pub const FILE_ADD_FILE: DWORD = asDword(c.FILE_ADD_FILE);
pub const FILE_ADD_SUBDIRECTORY: DWORD = asDword(c.FILE_ADD_SUBDIRECTORY);
pub const FILE_OPEN: DWORD = asDword(c.FILE_OPEN);
pub const FILE_CREATE: DWORD = asDword(c.FILE_CREATE);
pub const FILE_OPEN_IF: DWORD = asDword(c.FILE_OPEN_IF);
pub const FILE_OVERWRITE: DWORD = asDword(c.FILE_OVERWRITE);
pub const FILE_OVERWRITE_IF: DWORD = asDword(c.FILE_OVERWRITE_IF);
pub const STANDARD_RIGHTS_READ: DWORD = asDword(c.STANDARD_RIGHTS_READ);
pub const READ_CONTROL: DWORD = asDword(c.READ_CONTROL);
pub const SYNCHRONIZE: DWORD = asDword(c.SYNCHRONIZE);
pub const DELETE: DWORD = asDword(c.DELETE);
pub const GENERIC_READ: DWORD = asDword(c.GENERIC_READ);
pub const GENERIC_WRITE: DWORD = asDword(c.GENERIC_WRITE);
pub const FILE_GENERIC_READ: DWORD = asDword(c.FILE_GENERIC_READ);
pub const FILE_GENERIC_WRITE: DWORD = asDword(c.FILE_GENERIC_WRITE);
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = asDword(c.FILE_FLAG_BACKUP_SEMANTICS);
pub const FILE_FLAG_NO_BUFFERING: DWORD = asDword(c.FILE_FLAG_NO_BUFFERING);
pub const FILE_FLAG_SEQUENTIAL_SCAN: DWORD = asDword(c.FILE_FLAG_SEQUENTIAL_SCAN);
pub const FILE_FLAG_WRITE_THROUGH: DWORD = asDword(c.FILE_FLAG_WRITE_THROUGH);
pub const CREATE_NEW: DWORD = asDword(c.CREATE_NEW);
pub const OPEN_EXISTING: DWORD = asDword(c.OPEN_EXISTING);
pub const OPEN_ALWAYS: DWORD = asDword(c.OPEN_ALWAYS);
pub const TRUNCATE_EXISTING: DWORD = asDword(c.TRUNCATE_EXISTING);
pub const SYMBOLIC_LINK_FLAG_DIRECTORY: DWORD = asDword(c.SYMBOLIC_LINK_FLAG_DIRECTORY);
pub const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE: DWORD = asDword(c.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE);
pub const STD_INPUT_HANDLE: DWORD = asDword(c.STD_INPUT_HANDLE);
pub const STD_OUTPUT_HANDLE: DWORD = asDword(c.STD_OUTPUT_HANDLE);
pub const STD_ERROR_HANDLE: DWORD = asDword(c.STD_ERROR_HANDLE);
pub const PIPE_ACCESS_INBOUND: DWORD = asDword(c.PIPE_ACCESS_INBOUND);
pub const PIPE_ACCESS_OUTBOUND: DWORD = asDword(c.PIPE_ACCESS_OUTBOUND);
pub const PIPE_TYPE_BYTE: DWORD = asDword(c.PIPE_TYPE_BYTE);
pub const PIPE_READMODE_BYTE: DWORD = asDword(c.PIPE_READMODE_BYTE);
pub const PIPE_WAIT: DWORD = asDword(c.PIPE_WAIT);
pub const FILE_FLAG_OVERLAPPED: DWORD = asDword(c.FILE_FLAG_OVERLAPPED);
pub const FILE_ACTION_ADDED: DWORD = asDword(c.FILE_ACTION_ADDED);
pub const FILE_ACTION_REMOVED: DWORD = asDword(c.FILE_ACTION_REMOVED);
pub const FILE_ACTION_MODIFIED: DWORD = asDword(c.FILE_ACTION_MODIFIED);
pub const FILE_ACTION_RENAMED_OLD_NAME: DWORD = asDword(c.FILE_ACTION_RENAMED_OLD_NAME);
pub const FILE_ACTION_RENAMED_NEW_NAME: DWORD = asDword(c.FILE_ACTION_RENAMED_NEW_NAME);
pub const FILE_BASIC_INFORMATION = windows.FILE.BASIC_INFORMATION;
pub const FILE_END_OF_FILE_INFORMATION = windows.FILE.END_OF_FILE_INFORMATION;
pub const FILE_NOTIFY_INFORMATION = c.FILE_NOTIFY_INFORMATION;
pub const FILE_DISPOSITION_INFORMATION_EX = c.FILE_DISPOSITION_INFORMATION_EX;
pub const FILE_RENAME_INFORMATION_EX = extern struct {
    Flags: ULONG,
    RootDirectory: ?HANDLE,
    FileNameLength: ULONG,
    FileName: [1]WCHAR,
};
pub const FILE_RENAME_REPLACE_IF_EXISTS: ULONG = 0x1;
pub const FILE_RENAME_POSIX_SEMANTICS: ULONG = 0x2;
pub const FILE_RENAME_IGNORE_READONLY_ATTRIBUTE: ULONG = 0x40;
pub const CONSOLE_SCREEN_BUFFER_INFO = c.CONSOLE_SCREEN_BUFFER_INFO;
pub const GetFinalPathNameByHandleFormat = std.Io.Threaded.GetFinalPathNameByHandleFormat;
pub const GetFinalPathNameByHandleError = std.Io.Threaded.GetFinalPathNameByHandleError;
pub const user32 = windows.user32;
pub const advapi32 = windows.advapi32;

pub const INVALID_FILE_ATTRIBUTES: u32 = std.math.maxInt(u32);

fn asDword(comptime value: anytype) DWORD {
    return if (@bitSizeOf(@TypeOf(value)) == 64)
        @truncate(@as(u64, @bitCast(value)))
    else
        @as(u32, @bitCast(value));
}

pub const nt_object_prefix = [4]u16{ '\\', '?', '?', '\\' };
pub const nt_unc_object_prefix = [8]u16{ '\\', '?', '?', '\\', 'U', 'N', 'C', '\\' };
pub const long_path_prefix = [4]u16{ '\\', '\\', '?', '\\' };

pub const nt_object_prefix_u8 = [4]u8{ '\\', '?', '?', '\\' };
pub const nt_unc_object_prefix_u8 = [8]u8{ '\\', '?', '?', '\\', 'U', 'N', 'C', '\\' };
pub const long_path_prefix_u8 = [4]u8{ '\\', '\\', '?', '\\' };

pub const PathBuffer = if (Environment.isWindows) bun.PathBuffer else void;
pub const WPathBuffer = if (Environment.isWindows) bun.WPathBuffer else void;

pub const HANDLE = win32.HANDLE;
pub const HMODULE = win32.HMODULE;
pub const NtCreateFile = @import("../../windows_sys/externs.zig").NtCreateFile;
pub const GetStdHandle = @import("../../windows_sys/externs.zig").GetStdHandle;
pub const GetQueuedCompletionStatus = @import("../../windows_sys/externs.zig").GetQueuedCompletionStatus;
pub const PostQueuedCompletionStatus = @import("../../windows_sys/externs.zig").PostQueuedCompletionStatus;
pub const ReadDirectoryChangesW = @import("../../windows_sys/externs.zig").ReadDirectoryChangesW;
pub const CreateFileW = @import("../../windows_sys/externs.zig").CreateFileW;
pub const SetFilePointerEx = @import("../../windows_sys/externs.zig").SetFilePointerEx;
pub const GetFileSizeEx = @import("../../windows_sys/externs.zig").GetFileSizeEx;
pub const MoveFileExW = @import("../../windows_sys/externs.zig").MoveFileExW;
pub const SetConsoleCtrlHandler = @import("../../windows_sys/externs.zig").SetConsoleCtrlHandler;

pub fn CreateIoCompletionPort(file: HANDLE, existing: ?HANDLE, completion_key: windows.ULONG_PTR, concurrency: DWORD) !HANDLE {
    return @import("../../windows_sys/externs.zig").CreateIoCompletionPort(file, existing, completion_key, concurrency) orelse error.Unexpected;
}

/// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle
pub const GetFileInformationByHandle = @import("../../windows_sys/externs.zig").GetFileInformationByHandle;

pub const CommandLineToArgvW = @import("../../windows_sys/externs.zig").CommandLineToArgvW;

pub fn GetFileType(hFile: win32.HANDLE) win32.DWORD {
    const function = struct {
        pub extern fn GetFileType(
            hFile: win32.HANDLE,
        ) callconv(.winapi) win32.DWORD;
    }.GetFileType;

    const rc = function(hFile);
    if (comptime Environment.enable_logs)
        bun.sys.syslog("GetFileType({f}) = {d}", .{ bun.FD.fromNative(hFile), rc });
    return rc;
}

/// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfiletype#return-value
pub const FILE_TYPE_UNKNOWN = 0x0000;
pub const FILE_TYPE_DISK = 0x0001;
pub const FILE_TYPE_CHAR = 0x0002;
pub const FILE_TYPE_PIPE = 0x0003;
pub const FILE_TYPE_REMOTE = 0x8000;

pub const LPDWORD = @import("../../windows_sys/externs.zig").LPDWORD;

pub const GetBinaryTypeW = @import("../../windows_sys/externs.zig").GetBinaryTypeW;

/// A 32-bit Windows-based application
pub const SCS_32BIT_BINARY = 0;
/// A 64-bit Windows-based application.
pub const SCS_64BIT_BINARY = 6;
/// An MS-DOS – based application
pub const SCS_DOS_BINARY = 1;
/// A 16-bit OS/2-based application
pub const SCS_OS216_BINARY = 5;
/// A PIF file that executes an MS-DOS – based application
pub const SCS_PIF_BINARY = 3;
/// A POSIX – based application
pub const SCS_POSIX_BINARY = 4;

/// Each process has a single current directory made up of two parts:
///
/// - A disk designator that is either a drive letter followed by a colon, or a server name and share name (\\servername\sharename)
/// - A directory on the disk designator
///
/// The current directory is shared by all threads of the process: If one thread changes the current directory, it affects all threads in the process. Multithreaded applications and shared library code should avoid calling the SetCurrentDirectory function due to the risk of affecting relative path calculations being performed by other threads. Conversely, multithreaded applications and shared library code should avoid using relative paths so that they are unaffected by changes to the current directory performed by other threads.
///
/// Note that the current directory for a process is locked while the process is executing. This will prevent the directory from being deleted, moved, or renamed.
pub const SetCurrentDirectoryW = @import("../../windows_sys/externs.zig").SetCurrentDirectoryW;
pub const SetCurrentDirectory = SetCurrentDirectoryW;
pub const SaferiIsExecutableFileType = @import("../../windows_sys/externs.zig").SaferiIsExecutableFileType;
pub const libuv = @import("../../libuv_sys/libuv.zig");

pub const GetProcAddress = @import("../../windows_sys/externs.zig").GetProcAddress;

pub fn GetProcAddressA(
    ptr: ?*anyopaque,
    utf8: [:0]const u8,
) ?*anyopaque {
    var wbuf: [2048]u16 = undefined;
    return GetProcAddress(ptr, bun.strings.toWPath(&wbuf, utf8).ptr);
}

pub const LoadLibraryA = @import("../../windows_sys/externs.zig").LoadLibraryA;

pub const CreateHardLinkW = struct {
    pub fn wrapper(newFileName: LPCWSTR, existingFileName: LPCWSTR, securityAttributes: ?*win32.SECURITY_ATTRIBUTES) BOOL {
        const run = struct {
            pub extern "kernel32" fn CreateHardLinkW(
                newFileName: LPCWSTR,
                existingFileName: LPCWSTR,
                securityAttributes: ?*win32.SECURITY_ATTRIBUTES,
            ) BOOL;
        }.CreateHardLinkW;

        const rc = run(newFileName, existingFileName, securityAttributes);
        if (comptime Environment.isDebug)
            bun.sys.syslog(
                "CreateHardLinkW({f}, {f}) = {d}",
                .{
                    bun.fmt.fmtOSPath(std.mem.span(newFileName), .{}),
                    bun.fmt.fmtOSPath(std.mem.span(existingFileName), .{}),
                    if (!rc.toBool()) @backingInt(GetLastError()) else 0,
                },
            );
        return rc;
    }
}.wrapper;

pub const CopyFileW = @import("../../windows_sys/externs.zig").CopyFileW;

pub const SetFileInformationByHandle = @import("../../windows_sys/externs.zig").SetFileInformationByHandle;

pub fn getLastErrno() bun.sys.E {
    return SystemErrno.fromWin32(GetLastError()).toE();
}

pub fn getLastError() anyerror {
    return bun.errnoToZigErr(getLastErrno());
}

pub const GetHostNameW = @import("../../windows_sys/externs.zig").GetHostNameW;

/// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
pub const GetTempPathW = @import("../../windows_sys/externs.zig").GetTempPathW;

pub const CreateJobObjectA = @import("../../windows_sys/externs.zig").CreateJobObjectA;

pub const AssignProcessToJobObject = @import("../../windows_sys/externs.zig").AssignProcessToJobObject;

pub const ResumeThread = @import("../../windows_sys/externs.zig").ResumeThread;

pub const JOBOBJECT_ASSOCIATE_COMPLETION_PORT = extern struct {
    CompletionKey: windows.PVOID,
    CompletionPort: HANDLE,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    ///Reserved
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: ULONGLONG,
    WriteOperationCount: ULONGLONG,
    OtherOperationCount: ULONGLONG,
    ReadTransferCount: ULONGLONG,
    WriteTransferCount: ULONGLONG,
    OtherTransferCount: ULONGLONG,
};

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: LARGE_INTEGER,
    PerJobUserTimeLimit: LARGE_INTEGER,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: *ULONG,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

pub const JobObjectAssociateCompletionPortInformation: DWORD = 7;
pub const JobObjectExtendedLimitInformation: DWORD = 9;

pub const SetInformationJobObject = @import("../../windows_sys/externs.zig").SetInformationJobObject;

// Found experimentally:
// #include <stdio.h>
// #include <windows.h>
//
// int main() {
//         printf("%ld\n", JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO);
//         printf("%ld\n", JOB_OBJECT_MSG_EXIT_PROCESS);
// }
//
// Output:
// 4
// 7
pub const JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO = 4;
pub const JOB_OBJECT_MSG_EXIT_PROCESS = 7;

pub const OpenProcess = @import("../../windows_sys/externs.zig").OpenProcess;

// https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

pub fn exePathW() [:0]const u16 {
    const image_path_unicode_string = &std.os.windows.peb().ProcessParameters.ImagePathName;
    return image_path_unicode_string.Buffer.?[0 .. image_path_unicode_string.Length / 2 :0];
}

pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    uChar: extern union {
        UnicodeChar: WCHAR,
        AsciiChar: CHAR,
    },
    dwControlKeyState: DWORD,
};

pub const MOUSE_EVENT_RECORD = extern struct {
    dwMousePosition: COORD,
    dwButtonState: COORD,
    dwControlKeyState: DWORD,
    dwEventFlags: DWORD,
};

pub const WINDOW_BUFFER_SIZE_EVENT = extern struct {
    dwSize: COORD,
};

pub const MENU_EVENT_RECORD = extern struct {
    dwCommandId: UINT,
};

pub const FOCUS_EVENT_RECORD = extern struct {
    bSetFocus: BOOL,
};

pub const INPUT_RECORD = extern struct {
    EventType: WORD,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        MouseEvent: MOUSE_EVENT_RECORD,
        WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_EVENT,
        MenuEvent: MENU_EVENT_RECORD,
        FocusEvent: FOCUS_EVENT_RECORD,
    },
};

// Bun__UVSignalHandle__{init,close}: see src/runtime/node/uv_signal_handle_windows.zig

comptime {
    if (Environment.isWindows) {
        @export(&@"windows process.dlopen", .{ .name = "Bun__LoadLibraryBunString" });
    }
}

/// Is not the actual UID of the user, but just a hash of username.
pub fn userUniqueId() u32 {
    // https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tsch/165836c1-89d7-4abb-840d-80cf2510aa3e
    // UNLEN + 1
    var buf: [257]u16 = undefined;
    var size: u32 = buf.len;
    if (!GetUserNameW(@ptrCast(&buf), &size).toBool()) {
        if (Environment.isDebug) std.debug.panic("GetUserNameW failed: {}", .{bun.windows.GetLastError()});
        return 0;
    }
    const name = buf[0..size];
    bun.Output.scoped(.windowsUserUniqueId, .visible)("username: {f}", .{bun.fmt.utf16(name)});
    return bun.hash32(std.mem.sliceAsBytes(name));
}

// BOOL CreateDirectoryExW(
//   [in]           LPCWSTR               lpTemplateDirectory,
//   [in]           LPCWSTR               lpNewDirectory,
//   [in, optional] LPSECURITY_ATTRIBUTES lpSecurityAttributes
// );
pub const CreateDirectoryExW = @import("../../windows_sys/externs.zig").CreateDirectoryExW;

pub fn GetFinalPathNameByHandle(
    hFile: HANDLE,
    fmt: GetFinalPathNameByHandleFormat,
    out_buffer: []u16,
) GetFinalPathNameByHandleError![]u16 {
    const return_length = bun.windows.GetFinalPathNameByHandleW(hFile, out_buffer.ptr, @truncate(out_buffer.len), switch (fmt.volume_name) {
        .Dos => c.FILE_NAME_NORMALIZED | c.VOLUME_NAME_DOS,
        .Nt => c.FILE_NAME_NORMALIZED | c.VOLUME_NAME_NT,
    });

    if (return_length == 0) {
        bun.sys.syslog("GetFinalPathNameByHandleW({*p}) = {}", .{ hFile, GetLastError() });
        return error.FileNotFound;
    }

    if (return_length >= out_buffer.len) {
        bun.sys.syslog("GetFinalPathNameByHandleW({*p}) = NAMETOOLONG (needed {d}, have {d})", .{ hFile, return_length, out_buffer.len });
        return error.NameTooLong;
    }

    var ret = out_buffer[0..@intCast(return_length)];

    bun.sys.syslog("GetFinalPathNameByHandleW({*p}) = {f}", .{ hFile, bun.fmt.utf16(ret) });

    if (bun.strings.hasPrefixComptimeType(u16, ret, long_path_prefix)) {
        // '\\?\C:\absolute\path' -> 'C:\absolute\path'
        ret = ret[4..];
        if (bun.strings.hasPrefixComptimeUTF16(ret, "UNC\\")) {
            // '\\?\UNC\absolute\path' -> '\\absolute\path'
            ret[2] = '\\';
            ret = ret[2..];
        }
    }

    return ret;
}

const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x00000004;

pub fn getModuleHandleFromAddress(addr: usize) ?HMODULE {
    var module: HMODULE = undefined;
    const rc = GetModuleHandleExW(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
        @ptrFromInt(addr),
        &module,
    );
    // If the function succeeds, the return value is nonzero.
    return if (rc.toBool()) module else null;
}

pub fn getModuleNameW(module: HMODULE, buf: []u16) ?[]const u16 {
    const rc = GetModuleFileNameW(module, @ptrCast(buf.ptr), @intCast(buf.len));
    if (rc == 0) return null;
    return buf[0..@intCast(rc)];
}

pub const GetThreadDescription = @import("../../windows_sys/externs.zig").GetThreadDescription;
pub const LoadLibraryExW = @import("../../windows_sys/externs.zig").LoadLibraryExW;

pub const ENABLE_ECHO_INPUT = 0x004;
pub const ENABLE_LINE_INPUT = 0x002;
pub const ENABLE_PROCESSED_INPUT = 0x001;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT = 0x200;
pub const ENABLE_WRAP_AT_EOL_OUTPUT = 0x0002;
pub const ENABLE_PROCESSED_OUTPUT = 0x0001;

pub const SetStdHandle = @import("../../windows_sys/externs.zig").SetStdHandle;
pub const GetConsoleOutputCP = @import("../../windows_sys/externs.zig").GetConsoleOutputCP;
pub const GetConsoleCP = @import("../../windows_sys/externs.zig").GetConsoleCP;
pub const SetConsoleCP = @import("../../windows_sys/externs.zig").SetConsoleCP;

pub const DeleteFileOptions = struct {
    dir: ?HANDLE,
    remove_dir: bool = false,
};

const FILE_DISPOSITION_DELETE: ULONG = 0x00000001;
const FILE_DISPOSITION_POSIX_SEMANTICS: ULONG = 0x00000002;
const FILE_DISPOSITION_FORCE_IMAGE_SECTION_CHECK: ULONG = 0x00000004;
const FILE_DISPOSITION_ON_CLOSE: ULONG = 0x00000008;
const FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE: ULONG = 0x00000010;

// Copy-paste of the standard library function except without unreachable.
pub fn DeleteFileBun(sub_path_w: []const u16, options: DeleteFileOptions) bun.sys.Maybe(void) {
    const create_options_flags: ULONG = if (options.remove_dir)
        FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT
    else
        FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT; // would we ever want to delete the target instead?

    const path_len_bytes = @as(u16, @intCast(sub_path_w.len * 2));
    var nt_name = UNICODE_STRING{
        .Length = path_len_bytes,
        .MaximumLength = path_len_bytes,
        // The Windows API makes this mutable, but it will not mutate here.
        .Buffer = @constCast(sub_path_w.ptr),
    };

    if (sub_path_w[0] == '.' and sub_path_w[1] == 0) {
        // Windows does not recognize this, but it does work with empty string.
        nt_name.Length = 0;
    }

    var attr = OBJECT_ATTRIBUTES{
        .Length = @sizeOf(OBJECT_ATTRIBUTES),
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(sub_path_w)) null else options.dir,
        .Attributes = .{}, // Note we do not use OBJ_CASE_INSENSITIVE here.
        .ObjectName = &nt_name,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var io: IO_STATUS_BLOCK = undefined;
    var tmp_handle: HANDLE = undefined;
    var rc = NtCreateFile(
        &tmp_handle,
        SYNCHRONIZE | DELETE,
        &attr,
        &io,
        null,
        0,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        FILE_OPEN,
        create_options_flags,
        null,
        0,
    );
    bun.sys.syslog("NtCreateFile({f}, DELETE) = {}", .{ bun.fmt.fmtPath(u16, sub_path_w, .{}), rc });
    if (bun.sys.Maybe(void).errnoSys(rc, .open)) |err| {
        return err;
    }
    defer _ = bun.windows.CloseHandle(tmp_handle);

    // FileDispositionInformationEx (and therefore FILE_DISPOSITION_POSIX_SEMANTICS and FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE)
    // are only supported on NTFS filesystems, so the version check on its own is only a partial solution. To support non-NTFS filesystems
    // like FAT32, we need to fallback to FileDispositionInformation if the usage of FileDispositionInformationEx gives
    // us INVALID_PARAMETER.
    // The same reasoning for win10_rs5 as in os.renameatW() applies (FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE requires >= win10_rs5).
    var need_fallback = true;
    // Deletion with posix semantics if the filesystem supports it.
    var info = windows.FILE.DISPOSITION.INFORMATION.EX{
        .Flags = .{
            .DELETE = true,
            .POSIX_SEMANTICS = true,
            .IGNORE_READONLY_ATTRIBUTE = true,
        },
    };

    rc = ntdll.NtSetInformationFile(
        tmp_handle,
        &io,
        &info,
        @sizeOf(windows.FILE.DISPOSITION.INFORMATION.EX),
        .DispositionEx,
    );
    bun.sys.syslog("NtSetInformationFile({f}, DELETE) = {}", .{ bun.fmt.fmtPath(u16, sub_path_w, .{}), rc });
    switch (rc) {
        .SUCCESS => return .success,
        // INVALID_PARAMETER here means that the filesystem does not support FileDispositionInformationEx
        .INVALID_PARAMETER => {},
        // For all other statuses, fall down to the switch below to handle them.
        else => need_fallback = false,
    }
    if (need_fallback) {
        // Deletion with file pending semantics, which requires waiting or moving
        // files to get them removed (from here).
        var file_dispo = windows.FILE.DISPOSITION.INFORMATION{
            .DeleteFile = .TRUE,
        };

        rc = ntdll.NtSetInformationFile(
            tmp_handle,
            &io,
            &file_dispo,
            @sizeOf(windows.FILE.DISPOSITION.INFORMATION),
            .Disposition,
        );
        bun.sys.syslog("NtSetInformationFile({f}, DELETE) = {}", .{ bun.fmt.fmtPath(u16, sub_path_w, .{}), rc });
    }
    if (bun.sys.Maybe(void).errnoSys(rc, .NtSetInformationFile)) |err| {
        return err;
    }

    return .success;
}

pub const EXCEPTION_CONTINUE_EXECUTION = -1;
pub const MS_VC_EXCEPTION = 0x406d1388;

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: std.os.windows.STARTUPINFOW,
    lpAttributeList: [*]u8,
};

pub const InitializeProcThreadAttributeList = @import("../../windows_sys/externs.zig").InitializeProcThreadAttributeList;

pub const UpdateProcThreadAttribute = @import("../../windows_sys/externs.zig").UpdateProcThreadAttribute;

pub const IsProcessInJob = @import("../../windows_sys/externs.zig").IsProcessInJob;

pub const EXTENDED_STARTUPINFO_PRESENT = 0x80000;
pub const PROC_THREAD_ATTRIBUTE_JOB_LIST = 0x2000D;

/// Handle to a Windows pseudoconsole (ConPTY).
pub const HPCON = @import("../../windows_sys/externs.zig").HPCON;

pub const CreatePseudoConsole = @import("../../windows_sys/externs.zig").CreatePseudoConsole;

pub const ResizePseudoConsole = @import("../../windows_sys/externs.zig").ResizePseudoConsole;

pub const ClosePseudoConsole = @import("../../windows_sys/externs.zig").ClosePseudoConsole;

pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
pub const JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION = 0x400;
pub const JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x800;
pub const JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000;

const pe_header_offset_location = 0x3C;
const subsystem_offset = 0x5C;

pub const Subsystem = enum(u16) {
    windows_gui = 2,
};

pub fn editWin32BinarySubsystem(fd: bun.sys.File, subsystem: Subsystem) !void {
    comptime bun.assert(bun.Environment.isWindows);
    if (c.SetFilePointerEx(fd.handle.cast(), pe_header_offset_location, null, FILE_BEGIN) == 0)
        return error.Win32Error;
    const offset = try fd.reader().readInt(u32, .little);
    if (c.SetFilePointerEx(fd.handle.cast(), offset + subsystem_offset, null, FILE_BEGIN) == 0)
        return error.Win32Error;
    try fd.writer().writeInt(u16, @backingInt(subsystem), .little);
}

pub const rescle = struct {
    extern fn rescle__setIcon([*:0]const u16, [*:0]const u16) c_int;
    extern fn rescle__setWindowsMetadata(
        [*:0]const u16, // exe_path
        ?[*:0]const u16, // icon_path (nullable)
        ?[*:0]const u16, // title (nullable)
        ?[*:0]const u16, // publisher (nullable)
        ?[*:0]const u16, // version (nullable)
        ?[*:0]const u16, // description (nullable)
        ?[*:0]const u16, // copyright (nullable)
    ) c_int;

    pub fn setIcon(exe_path: [*:0]const u16, icon: [*:0]const u16) !void {
        comptime bun.assert(bun.Environment.isWindows);
        const status = rescle__setIcon(exe_path, icon);
        return switch (status) {
            0 => {},
            else => error.IconEditError,
        };
    }

    pub fn setWindowsMetadata(
        exe_path: [*:0]const u16,
        icon: ?[]const u8,
        title: ?[]const u8,
        publisher: ?[]const u8,
        version: ?[]const u8,
        description: ?[]const u8,
        copyright: ?[]const u8,
    ) !void {
        comptime bun.assert(bun.Environment.isWindows);

        // Validate version string format if provided
        if (version) |v| {
            // Empty version string is invalid
            if (v.len == 0) {
                return error.InvalidVersionFormat;
            }

            // Basic validation: check format and ranges
            var parts_count: u32 = 0;
            var iter = std.mem.tokenizeAny(u8, v, ".");
            while (iter.next()) |part| : (parts_count += 1) {
                if (parts_count >= 4) {
                    return error.InvalidVersionFormat;
                }
                const num = std.fmt.parseInt(u16, part, 10) catch {
                    return error.InvalidVersionFormat;
                };
                // u16 already ensures value is 0-65535
                _ = num;
            }
            if (parts_count == 0) {
                return error.InvalidVersionFormat;
            }
        }

        // Allocate UTF-16 strings
        const allocator = bun.default_allocator;

        // Icon is a path, so use toWPathNormalized with proper buffer handling
        var icon_buf: bun.OSPathBuffer = undefined;
        const icon_w = if (icon) |i| brk: {
            const path_w = bun.strings.toWPathNormalized(&icon_buf, i);
            // toWPathNormalized returns a slice into icon_buf, need to null-terminate it
            const buf_u16 = bun.reinterpretSlice(u16, &icon_buf);
            buf_u16[path_w.len] = 0;
            break :brk buf_u16[0..path_w.len :0];
        } else null;

        const title_w = if (title) |t| try bun.strings.toUTF16AllocForReal(allocator, t, false, true) else null;
        defer if (title_w) |tw| allocator.free(tw);

        const publisher_w = if (publisher) |p| try bun.strings.toUTF16AllocForReal(allocator, p, false, true) else null;
        defer if (publisher_w) |pw| allocator.free(pw);

        const version_w = if (version) |v| try bun.strings.toUTF16AllocForReal(allocator, v, false, true) else null;
        defer if (version_w) |vw| allocator.free(vw);

        const description_w = if (description) |d| try bun.strings.toUTF16AllocForReal(allocator, d, false, true) else null;
        defer if (description_w) |dw| allocator.free(dw);

        const copyright_w = if (copyright) |cr| try bun.strings.toUTF16AllocForReal(allocator, cr, false, true) else null;
        defer if (copyright_w) |cw| allocator.free(cw);

        const status = rescle__setWindowsMetadata(
            exe_path,
            if (icon_w) |iw| iw.ptr else null,
            if (title_w) |tw| tw.ptr else null,
            if (publisher_w) |pw| pw.ptr else null,
            if (version_w) |vw| vw.ptr else null,
            if (description_w) |dw| dw.ptr else null,
            if (copyright_w) |cw| cw.ptr else null,
        );
        return switch (status) {
            0 => {},
            -1 => error.FailedToLoadExecutable,
            -2 => error.FailedToSetIcon,
            -3 => error.FailedToSetProductName,
            -4 => error.FailedToSetCompanyName,
            -5 => error.FailedToSetDescription,
            -6 => error.FailedToSetCopyright,
            -7 => error.FailedToSetFileVersion,
            -8 => error.FailedToSetProductVersion,
            -9 => error.FailedToSetFileVersionString,
            -10 => error.FailedToSetProductVersionString,
            -11 => error.InvalidVersionFormat,
            -12 => error.FailedToCommit,
            else => error.WindowsMetadataEditError,
        };
    }
};

pub const CloseHandle = @import("../../windows_sys/externs.zig").CloseHandle;
pub const GetFinalPathNameByHandleW = @import("../../windows_sys/externs.zig").GetFinalPathNameByHandleW;
pub const DeleteFileW = @import("../../windows_sys/externs.zig").DeleteFileW;
pub const CreateSymbolicLinkW = @import("../../windows_sys/externs.zig").CreateSymbolicLinkW;
pub const GetCurrentThread = @import("../../windows_sys/externs.zig").GetCurrentThread;
pub const GetCommandLineW = @import("../../windows_sys/externs.zig").GetCommandLineW;
pub const CreateDirectoryW = @import("../../windows_sys/externs.zig").CreateDirectoryW;
pub const SetEndOfFile = @import("../../windows_sys/externs.zig").SetEndOfFile;
pub const GetProcessTimes = @import("../../windows_sys/externs.zig").GetProcessTimes;

/// Returns the original mode, or null on failure
pub fn updateStdioModeFlags(i: bun.FD.Stdio, opts: struct { set: DWORD = 0, unset: DWORD = 0 }) !DWORD {
    const fd = i.fd();
    var original_mode: DWORD = 0;
    if (c.GetConsoleMode(fd.cast(), &original_mode) != 0) {
        if (c.SetConsoleMode(fd.cast(), (original_mode | opts.set) & ~opts.unset) == 0) {
            return getLastError();
        }
    } else return getLastError();
    return original_mode;
}

const watcherChildEnv: [:0]const u16 = bun.strings.toUTF16Literal("_BUN_WATCHER_CHILD");

// magic exit code to indicate to the watcher manager that the child process should be re-spawned
// this was randomly generated - we need to avoid using a common exit code that might be used by the script itself
pub const watcher_reload_exit: DWORD = 3224497970;

pub const spawn = @import("../../runtime/api/bun/spawn.zig").PosixSpawn;

pub fn isWatcherChild() bool {
    var buf: [1]u16 = undefined;
    return c.GetEnvironmentVariableW(@constCast(watcherChildEnv.ptr), &buf, 1) > 0;
}

pub fn becomeWatcherManager(allocator: std.mem.Allocator) noreturn {
    // this process will be the parent of the child process that actually runs the script
    var procinfo: std.os.windows.PROCESS.INFORMATION = undefined;
    windows_enable_stdio_inheritance();
    const job = CreateJobObjectA(null, null) orelse Output.panic(
        "Could not create watcher Job Object: {}",
        .{std.os.windows.GetLastError()},
    );
    var jeli = std.mem.zeroes(c.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    jeli.BasicLimitInformation.LimitFlags =
        c.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        c.JOB_OBJECT_LIMIT_BREAKAWAY_OK |
        c.JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK |
        c.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    if (c.SetInformationJobObject(
        job,
        c.JobObjectExtendedLimitInformation,
        &jeli,
        @sizeOf(c.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ) == 0) {
        Output.panic(
            "Could not configure watcher Job Object: {}",
            .{std.os.windows.GetLastError()},
        );
    }

    while (true) {
        spawnWatcherChild(allocator, &procinfo, job) catch |err| {
            bun.handleErrorReturnTrace(err, @errorReturnTrace());
            if (err == error.Win32Error) {
                Output.panic("Failed to spawn process: {}\n", .{GetLastError()});
            }
            Output.panic("Failed to spawn process: {s}\n", .{@errorName(err)});
        };
        if (c.WaitForSingleObject(procinfo.hProcess, c.INFINITE) == c.WAIT_FAILED) {
            Output.panic("Failed to wait for child process: {}\n", .{GetLastError()});
        }
        var exit_code: DWORD = 0;
        if (c.GetExitCodeProcess(procinfo.hProcess, &exit_code) == 0) {
            const err = windows.GetLastError();
            _ = c.NtClose(procinfo.hProcess);
            Output.panic("Failed to get exit code of child process: {}\n", .{err});
        }
        _ = c.NtClose(procinfo.hProcess);

        // magic exit code to indicate that the child process should be re-spawned
        if (exit_code == watcher_reload_exit) {
            continue;
        } else {
            bun.Global.exit(exit_code);
        }
    }
}

pub fn spawnWatcherChild(
    allocator: std.mem.Allocator,
    procinfo: *std.os.windows.PROCESS.INFORMATION,
    job: HANDLE,
) !void {
    // https://devblogs.microsoft.com/oldnewthing/20230209-00/?p=107812
    var attr_size: usize = undefined;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const p = try allocator.alloc(u8, attr_size);
    defer allocator.free(p);
    if (!InitializeProcThreadAttributeList(p.ptr, 1, 0, &attr_size).toBool()) {
        return error.Win32Error;
    }
    if (UpdateProcThreadAttribute(
        p.ptr,
        0,
        c.PROC_THREAD_ATTRIBUTE_JOB_LIST,
        @ptrCast(&job),
        @sizeOf(HANDLE),
        null,
        null,
    ).toBool() == false) {
        return error.Win32Error;
    }

    const flags: std.os.windows.CreateProcessFlags = .{ .create_unicode_environment = true, .extended_startupinfo_present = true };

    const image_path = exePathW();
    var wbuf: WPathBuffer = undefined;
    @memcpy(wbuf[0..image_path.len], image_path);
    wbuf[image_path.len] = 0;

    const image_pathZ = wbuf[0..image_path.len :0];

    const kernelenv = kernel32_2.GetEnvironmentStringsW();
    defer if (kernelenv) |envptr| {
        _ = kernel32_2.FreeEnvironmentStringsW(envptr);
    };

    var size: usize = 0;
    if (kernelenv) |pointer| {
        // check that env is non-empty
        if (pointer[0] != 0 or pointer[1] != 0) {
            // array is terminated by two nulls
            while (pointer[size] != 0 or pointer[size + 1] != 0) size += 1;
            size += 1;
        }
    }
    // now pointer[size] is the first null

    const envbuf = try allocator.alloc(u16, size + watcherChildEnv.len + 4);
    defer allocator.free(envbuf);
    if (kernelenv) |pointer| {
        @memcpy(envbuf[0..size], pointer);
    }
    @memcpy(envbuf[size .. size + watcherChildEnv.len], watcherChildEnv);
    envbuf[size + watcherChildEnv.len] = '=';
    envbuf[size + watcherChildEnv.len + 1] = '1';
    envbuf[size + watcherChildEnv.len + 2] = 0;
    envbuf[size + watcherChildEnv.len + 3] = 0;

    var startupinfo = STARTUPINFOEXW{
        .StartupInfo = .{
            .cb = @sizeOf(STARTUPINFOEXW),
            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .dwFlags = c.STARTF_USESTDHANDLES,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
            .hStdInput = std.Io.File.stdin().handle,
            .hStdOutput = std.Io.File.stdout().handle,
            .hStdError = std.Io.File.stderr().handle,
        },
        .lpAttributeList = p.ptr,
    };
    @memset(std.mem.asBytes(procinfo), 0);
    const rc = kernel32.CreateProcessW(
        image_pathZ.ptr,
        c.GetCommandLineW(),
        null,
        null,
        .TRUE,
        flags,
        @ptrCast(envbuf.ptr),
        null,
        @ptrCast(&startupinfo),
        procinfo,
    );
    if (!rc.toBool()) {
        return error.Win32Error;
    }
    var is_in_job: c.BOOL = 0;
    _ = c.IsProcessInJob(procinfo.hProcess, job, &is_in_job);
    bun.debugAssert(is_in_job != 0);
    _ = c.NtClose(procinfo.hThread);
}

/// Returns null on error. Use windows API to lookup the actual error.
/// The reason this function is in zig is so that we can use our own utf16-conversion functions.
///
/// Using characters16() does not seem to always have the sentinel. or something else
/// broke when I just used it. Not sure. ... but this works!
fn @"windows process.dlopen"(str: *bun.String) callconv(.c) ?*anyopaque {
    if (comptime !bun.Environment.isWindows) {
        @compileError("unreachable");
    }

    var buf: bun.WPathBuffer = undefined;
    const data = switch (str.encoding()) {
        .utf8 => bun.strings.convertUTF8toUTF16InBuffer(&buf, str.utf8()),
        .utf16 => brk: {
            @memcpy(buf[0..str.length()], str.utf16());
            break :brk buf[0..str.length()];
        },
        .latin1 => brk: {
            bun.strings.copyU8IntoU16(&buf, str.latin1());
            break :brk buf[0..str.length()];
        },
    };
    buf[data.len] = 0;
    const LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;
    return bun.windows.LoadLibraryExW(buf[0..data.len :0].ptr, null, LOAD_WITH_ALTERED_SEARCH_PATH);
}

pub const windows_enable_stdio_inheritance = @import("../../windows_sys/externs.zig").windows_enable_stdio_inheritance;

/// Extracted from standard library except this takes an open file descriptor
///
/// NOTE: THE FILE MUST BE OPENED WITH ACCESS_MASK "DELETE" OR THIS WILL FAIL
pub fn deleteOpenedFile(fd: bun.FD) Maybe(void) {
    comptime bun.assert(builtin.target.os.version_range.windows.min.isAtLeast(.win10_rs5));
    var info = w.FILE_DISPOSITION_INFORMATION_EX{
        .Flags = FILE_DISPOSITION_DELETE |
            FILE_DISPOSITION_POSIX_SEMANTICS |
            FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE,
    };

    var io: w.IO_STATUS_BLOCK = undefined;
    const rc = w.ntdll.NtSetInformationFile(
        fd.cast(),
        &io,
        &info,
        @sizeOf(w.FILE_DISPOSITION_INFORMATION_EX),
        .DispositionEx,
    );

    log("deleteOpenedFile({}) = {s}", .{ fd, @tagName(rc) });

    return if (rc == .SUCCESS)
        .success
    else
        .errno(rc, .NtSetInformationFile);
}

/// With an open file source_fd, move it into the directory new_dir_fd with the name new_path_w.
/// Does not close the file descriptor.
///
/// For this to succeed
/// - source_fd must have been opened with access_mask=w.DELETE
/// - new_path_w must be the name of a file. it cannot be a path relative to new_dir_fd. see moveOpenedFileAtLoose
pub fn moveOpenedFileAt(
    src_fd: bun.FD,
    new_dir_fd: bun.FD,
    new_file_name: []const u16,
    replace_if_exists: bool,
) Maybe(void) {
    // FILE_RENAME_INFORMATION_EX and FILE_RENAME_POSIX_SEMANTICS require >= win10_rs1,
    // but FILE_RENAME_IGNORE_READONLY_ATTRIBUTE requires >= win10_rs5. We check >= rs5 here
    // so that we only use POSIX_SEMANTICS when we know IGNORE_READONLY_ATTRIBUTE will also be
    // supported in order to avoid either (1) using a redundant call that we can know in advance will return
    // STATUS_NOT_SUPPORTED or (2) only setting IGNORE_READONLY_ATTRIBUTE when >= rs5
    // and therefore having different behavior when the Windows version is >= rs1 but < rs5.
    comptime bun.assert(builtin.target.os.version_range.windows.min.isAtLeast(.win10_rs5));

    if (bun.Environment.allow_assert) {
        bun.assert(std.mem.indexOfScalar(u16, new_file_name, '/') == null); // Call moveOpenedFileAtLoose
    }

    const struct_buf_len = @sizeOf(w.FILE_RENAME_INFORMATION_EX) + (bun.MAX_PATH_BYTES - 1);
    var rename_info_buf: [struct_buf_len]u8 align(@alignOf(w.FILE_RENAME_INFORMATION_EX)) = undefined;

    const struct_len = @sizeOf(w.FILE_RENAME_INFORMATION_EX) - 1 + new_file_name.len * 2;
    if (struct_len > struct_buf_len) return Maybe(void).errno(bun.sys.E.NAMETOOLONG, .NtSetInformationFile);

    const rename_info = @as(*w.FILE_RENAME_INFORMATION_EX, @ptrCast(&rename_info_buf));
    var io_status_block: w.IO_STATUS_BLOCK = undefined;

    var flags: w.ULONG = w.FILE_RENAME_POSIX_SEMANTICS | w.FILE_RENAME_IGNORE_READONLY_ATTRIBUTE;
    if (replace_if_exists) flags |= w.FILE_RENAME_REPLACE_IF_EXISTS;
    rename_info.* = .{
        .Flags = flags,
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(new_file_name)) null else new_dir_fd.cast(),
        .FileNameLength = @intCast(new_file_name.len * 2), // already checked error.NameTooLong
        .FileName = undefined,
    };
    @memcpy(@as([*]u16, &rename_info.FileName)[0..new_file_name.len], new_file_name);
    const rc = w.ntdll.NtSetInformationFile(
        src_fd.cast(),
        &io_status_block,
        rename_info,
        @intCast(struct_len), // already checked for error.NameTooLong
        .RenameEx,
    );
    log("moveOpenedFileAt({f} ->> {f} '{f}', {s}) = {s}", .{ src_fd, new_dir_fd, bun.fmt.utf16(new_file_name), if (replace_if_exists) "replace_if_exists" else "no flag", @tagName(rc) });

    if (bun.Environment.isDebug) {
        if (rc == .ACCESS_DENIED) {
            bun.Output.debugWarn("moveOpenedFileAt was called on a file descriptor without access_mask=w.DELETE", .{});
        }
    }

    return if (rc == .SUCCESS)
        .success
    else
        .errno(rc, .NtSetInformationFile);
}

/// Same as moveOpenedFileAt but allows new_path to be a path relative to new_dir_fd.
///
/// Aka: moveOpenedFileAtLoose(fd, dir, ".\\a\\relative\\not-normalized-path.txt", false);
pub fn moveOpenedFileAtLoose(
    src_fd: bun.FD,
    new_dir_fd: bun.FD,
    new_path: []const u16,
    replace_if_exists: bool,
) Maybe(void) {
    bun.assert(std.mem.indexOfScalar(u16, new_path, '/') == null); // Call bun.strings.toWPathNormalized first

    const without_leading_dot_slash = if (new_path.len >= 2 and new_path[0] == '.' and new_path[1] == '\\')
        new_path[2..]
    else
        new_path;

    if (std.mem.lastIndexOfScalar(u16, new_path, '\\')) |last_slash| {
        const dirname = new_path[0..last_slash];
        const fd = switch (bun.sys.openDirAtWindows(new_dir_fd, dirname, .{ .can_rename_or_delete = true, .iterable = false })) {
            .err => |e| return .{ .err = e },
            .result => |fd| fd,
        };
        defer fd.close();

        const basename = new_path[last_slash + 1 ..];
        return moveOpenedFileAt(src_fd, fd, basename, replace_if_exists);
    }

    // easy mode
    return moveOpenedFileAt(src_fd, new_dir_fd, without_leading_dot_slash, replace_if_exists);
}

/// Derived from std.os.windows.renameAtW
/// Allows more errors
pub fn renameAtW(
    old_dir_fd: bun.FD,
    old_path_w: []const u16,
    new_dir_fd: bun.FD,
    new_path_w: []const u16,
    replace_if_exists: bool,
) Maybe(void) {
    const src_fd = brk: {
        switch (bun.sys.openFileAtWindows(
            old_dir_fd,
            old_path_w,
            .{
                .access_mask = w.SYNCHRONIZE | w.GENERIC_WRITE | w.DELETE | w.FILE_TRAVERSE,
                .disposition = w.FILE_OPEN,
                .options = w.FILE_SYNCHRONOUS_IO_NONALERT | w.FILE_OPEN_REPARSE_POINT,
            },
        )) {
            .err => {
                // retry, wtihout FILE_TRAVERSE flag
                switch (bun.sys.openFileAtWindows(
                    old_dir_fd,
                    old_path_w,
                    .{
                        .access_mask = w.SYNCHRONIZE | w.GENERIC_WRITE | w.DELETE,
                        .disposition = w.FILE_OPEN,
                        .options = w.FILE_SYNCHRONOUS_IO_NONALERT | w.FILE_OPEN_REPARSE_POINT,
                    },
                )) {
                    .err => |err2| return .{ .err = err2 },
                    .result => |fd| break :brk fd,
                }
            },
            .result => |fd| break :brk fd,
        }
    };
    defer src_fd.close();

    return moveOpenedFileAt(src_fd, new_dir_fd, new_path_w, replace_if_exists);
}

const kernel32_2 = struct {
    pub extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?LPWSTR;

    pub extern "kernel32" fn FreeEnvironmentStringsW(
        penv: LPWSTR,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn GetEnvironmentVariableW(
        lpName: ?LPCWSTR,
        lpBuffer: ?[*]WCHAR,
        nSize: DWORD,
    ) callconv(.winapi) DWORD;
};
pub const GetEnvironmentStringsError = error{OutOfMemory};

pub fn GetEnvironmentStringsW() GetEnvironmentStringsError![*:0]u16 {
    return kernel32_2.GetEnvironmentStringsW() orelse return error.OutOfMemory;
}

pub fn FreeEnvironmentStringsW(penv: [*:0]u16) void {
    std.debug.assert(kernel32_2.FreeEnvironmentStringsW(penv) != 0);
}

pub const GetEnvironmentVariableError = error{
    EnvironmentVariableNotFound,

    Unexpected,
};

pub fn GetEnvironmentVariableW(lpName: LPWSTR, lpBuffer: [*]u16, nSize: DWORD) GetEnvironmentVariableError!DWORD {
    const rc = kernel32_2.GetEnvironmentVariableW(lpName, lpBuffer, nSize);

    if (rc == 0) {
        switch (GetLastError()) {
            .ENVVAR_NOT_FOUND => return error.EnvironmentVariableNotFound,

            else => return error.Unexpected,
        }
    }

    return rc;
}

pub const env = @import("./env.zig");

const builtin = @import("builtin");
const std = @import("std");

const GetModuleFileNameW = @import("../../windows_sys/externs.zig").GetModuleFileNameW;
const GetModuleHandleExW = @import("../../windows_sys/externs.zig").GetModuleHandleExW;
const GetUserNameW = @import("../../windows_sys/externs.zig").GetUserNameW;

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const c = bun.c;

const Maybe = bun.sys.Maybe;
const SystemErrno = bun.sys.SystemErrno;
const log = bun.sys.syslog;

const w = @This();
const win32 = windows;
const windows = std.os.windows;
