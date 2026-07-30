//! Raw Win32 extern fn declarations split from sys/windows/windows.zig.
//! Helper wrappers stay in sys/windows/.

pub const LPDWORD = *DWORD;
pub const HPCON = *anyopaque;
pub const HRESULT = i32;

pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: windows.FILETIME,
    ftLastAccessTime: windows.FILETIME,
    ftLastWriteTime: windows.FILETIME,
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
};

pub extern "ntdll" fn NtCreateFile(
    file_handle: *HANDLE,
    desired_access: ULONG,
    object_attributes: *const windows.OBJECT.ATTRIBUTES,
    io_status_block: *windows.IO_STATUS_BLOCK,
    allocation_size: ?*const windows.LARGE_INTEGER,
    file_attributes: ULONG,
    share_access: ULONG,
    create_disposition: ULONG,
    create_options: ULONG,
    ea_buffer: ?*const anyopaque,
    ea_length: ULONG,
) callconv(.winapi) windows.NTSTATUS;

pub extern "ntdll" fn RtlNtStatusToDosError(
    status: windows.NTSTATUS,
) callconv(.winapi) windows.Win32Error;

pub extern "kernel32" fn GetFileInformationByHandle(
    hFile: HANDLE,
    lpFileInformation: *BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn CreateIoCompletionPort(
    FileHandle: HANDLE,
    ExistingCompletionPort: ?HANDLE,
    CompletionKey: windows.ULONG_PTR,
    NumberOfConcurrentThreads: DWORD,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn GetQueuedCompletionStatus(
    CompletionPort: HANDLE,
    lpNumberOfBytesTransferred: *DWORD,
    lpCompletionKey: *windows.ULONG_PTR,
    lpOverlapped: *?*anyopaque,
    dwMilliseconds: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn PostQueuedCompletionStatus(
    CompletionPort: HANDLE,
    dwNumberOfBytesTransferred: DWORD,
    dwCompletionKey: windows.ULONG_PTR,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: HANDLE,
    lpBuffer: *anyopaque,
    nBufferLength: DWORD,
    bWatchSubtree: BOOL,
    dwNotifyFilter: DWORD,
    lpBytesReturned: ?*DWORD,
    lpOverlapped: ?*anyopaque,
    lpCompletionRoutine: ?*const anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn SetFilePointerEx(
    hFile: HANDLE,
    liDistanceToMove: windows.LARGE_INTEGER,
    lpNewFilePointer: ?*windows.LARGE_INTEGER,
    dwMoveMethod: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetFileSizeEx(
    hFile: HANDLE,
    lpFileSize: *windows.LARGE_INTEGER,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn MoveFileExW(
    lpExistingFileName: LPCWSTR,
    lpNewFileName: LPCWSTR,
    dwFlags: DWORD,
) callconv(.winapi) BOOL;

pub const ConsoleCtrlHandler = *const fn (DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?ConsoleCtrlHandler,
    add: BOOL,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CommandLineToArgvW(
    lpCmdLine: win32.LPCWSTR,
    pNumArgs: *c_int,
) callconv(.winapi) ?[*]win32.LPWSTR;

pub extern "kernel32" fn GetBinaryTypeW(
    lpApplicationName: win32.LPCWSTR,
    lpBinaryType: LPDWORD,
) callconv(.winapi) win32.BOOL;

pub extern "kernel32" fn SetCurrentDirectoryW(
    lpPathName: win32.LPCWSTR,
) callconv(.winapi) win32.BOOL;

pub extern "advapi32" fn SaferiIsExecutableFileType(szFullPathname: win32.LPCWSTR, bFromShellExecute: win32.BOOLEAN) callconv(.winapi) win32.BOOL;

pub extern fn GetProcAddress(
    ptr: ?*anyopaque,
    [*:0]const u16,
) ?*anyopaque;

pub extern fn LoadLibraryA(
    [*:0]const u8,
) ?*anyopaque;

pub extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: LPCWSTR,
    hFile: ?HANDLE,
    dwFlags: DWORD,
) callconv(.winapi) ?HMODULE;

pub extern "kernel32" fn CopyFileW(
    source: LPCWSTR,
    dest: LPCWSTR,
    bFailIfExists: BOOL,
) BOOL;

pub extern "kernel32" fn SetFileInformationByHandle(
    file: HANDLE,
    fileInformationClass: FILE_INFO_BY_HANDLE_CLASS,
    fileInformation: LPVOID,
    bufferSize: DWORD,
) BOOL;

pub extern "kernel32" fn GetHostNameW(
    lpBuffer: PWSTR,
    nSize: c_int,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetTempPathW(
    nBufferLength: DWORD, // [in]
    lpBuffer: LPCWSTR, // [out]
) DWORD;

pub extern "kernel32" fn CreateJobObjectA(
    lpJobAttributes: ?*anyopaque, // [in, optional]
    lpName: ?LPCSTR, // [in, optional]
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: HANDLE, // [in]
    hProcess: HANDLE, // [in]
) callconv(.winapi) BOOL;

pub extern "kernel32" fn ResumeThread(
    hJob: HANDLE, // [in]
) callconv(.winapi) DWORD;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInformationClass: DWORD,
    lpJobObjectInformation: LPVOID,
    cbJobObjectInformationLength: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) ?HANDLE;

pub extern fn GetUserNameW(
    lpBuffer: LPWSTR,
    pcbBuffer: LPDWORD,
) BOOL;

pub extern "kernel32" fn CreateDirectoryExW(
    lpTemplateDirectory: [*:0]const u16,
    lpNewDirectory: [*:0]const u16,
    lpSecurityAttributes: ?*win32.SECURITY_ATTRIBUTES,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetModuleHandleExW(
    dwFlags: u32, // [in]
    lpModuleName: ?*anyopaque, // [in, optional]
    phModule: *HMODULE, // [out]
) BOOL;

pub extern "kernel32" fn GetModuleFileNameW(
    hModule: HMODULE, // [in]
    lpFilename: LPWSTR, // [out]
    nSize: DWORD, // [in]
) DWORD;

pub extern "kernel32" fn GetThreadDescription(
    thread: ?*anyopaque, // [in]
    *PWSTR, // [out]
) HRESULT;

pub extern fn SetStdHandle(nStdHandle: u32, hHandle: *anyopaque) u32;

pub extern fn GetConsoleOutputCP() u32;

pub extern fn GetConsoleCP() u32;

pub extern "kernel32" fn SetConsoleCP(wCodePageID: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?[*]u8,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    size: *usize,
) BOOL;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: [*]u8, // [in, out]
    dwFlags: DWORD, // [in]
    Attribute: windows.DWORD_PTR, // [in]
    lpValue: *const anyopaque, // [in]
    cbSize: usize, // [in]
    lpPreviousValue: ?*anyopaque, // [out, optional]
    lpReturnSize: ?*usize, // [in, optional]
) BOOL;

pub extern "kernel32" fn IsProcessInJob(process: HANDLE, job: HANDLE, result: *BOOL) BOOL;

pub extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetFinalPathNameByHandleW(hFile: HANDLE, lpszFilePath: [*]u16, cchFilePath: DWORD, dwFlags: DWORD) callconv(.winapi) DWORD;

pub extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateSymbolicLinkW(lpSymlinkFileName: [*:0]const u16, lpTargetFileName: [*:0]const u16, dwFlags: DWORD) callconv(.winapi) BOOLEAN;

pub extern "kernel32" fn GetCurrentThread() callconv(.winapi) HANDLE;

pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) LPWSTR;

pub extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetEndOfFile(hFile: HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetProcessTimes(in_hProcess: HANDLE, out_lpCreationTime: *FILETIME, out_lpExitTime: *FILETIME, out_lpKernelTime: *FILETIME, out_lpUserTime: *FILETIME) callconv(.winapi) BOOL;

pub extern fn windows_enable_stdio_inheritance() void;

const std = @import("std");

const win32 = std.os.windows;
const windows = std.os.windows;
const BOOL = windows.BOOL;
const BOOLEAN = windows.BOOLEAN;
const COORD = windows.COORD;
const DWORD = windows.DWORD;
const FILETIME = windows.FILETIME;
const FILE_INFO_BY_HANDLE_CLASS = windows.FILE_INFO_BY_HANDLE_CLASS;
const HANDLE = windows.HANDLE;
const HMODULE = windows.HMODULE;
const LPCSTR = windows.LPCSTR;
const LPCWSTR = windows.LPCWSTR;
const LPVOID = windows.LPVOID;
const LPWSTR = windows.LPWSTR;
const PWSTR = windows.PWSTR;
const UINT = windows.UINT;
const ULONG = windows.ULONG;
