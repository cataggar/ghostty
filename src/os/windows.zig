const std = @import("std");
const windows = std.os.windows;

// Export any constants or functions we need from the Windows API so
// we can just import one file.
pub const kernel32 = windows.kernel32;
pub const ntdll = windows.ntdll;
pub const GetLastError = windows.GetLastError;
pub const unexpectedError = windows.unexpectedError;
pub const unexpectedStatus = windows.unexpectedStatus;
pub const CloseHandle = windows.CloseHandle;
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const DWORD = windows.DWORD;
pub const FILE_ATTRIBUTE_NORMAL = 0x00000080;
pub const FILE_SHARE_READ = 0x00000001;
pub const FILE_SHARE_WRITE = 0x00000002;
pub const GENERIC_READ = 0x80000000;
pub const GENERIC_WRITE = 0x40000000;
pub const HANDLE = windows.HANDLE;
pub const HANDLE_FLAG_INHERIT = 0x00000001;
pub const INFINITE = windows.INFINITE;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const OPEN_EXISTING = 3;
pub const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: windows.DWORD,
    dwThreadId: windows.DWORD,
};
pub const HRESULT = windows.LONG;
pub const S_OK: HRESULT = 0;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const SYNCHRONIZE = windows.SYNCHRONIZE;
pub const WAIT_FAILED = windows.WAIT_FAILED;
pub const FALSE = windows.BOOL.FALSE;
pub const TRUE = windows.BOOL.TRUE;

pub fn SetHandleInformation(
    handle: windows.HANDLE,
    mask: windows.DWORD,
    flags: windows.DWORD,
) std.Io.UnexpectedError!void {
    if (exp.kernel32.SetHandleInformation(handle, mask, flags) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

pub const exp = struct {
    pub const HPCON = windows.LPVOID;

    pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
    pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
    pub const FILE_FLAG_OVERLAPPED = 0x40000000;
    pub const PIPE_ACCESS_OUTBOUND = 0x00000002;
    pub const PIPE_TYPE_BYTE = 0x00000000;
    pub const MEM_COMMIT = 0x00001000;
    pub const MEM_RESERVE = 0x00002000;
    pub const MEM_RELEASE = 0x00008000;
    pub const PAGE_READWRITE = 0x04;

    pub const STATUS_PENDING = 0x00000103;
    pub const STILL_ACTIVE = STATUS_PENDING;

    pub const STARTUPINFOEX = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    };

    pub const kernel32 = struct {
        pub extern "kernel32" fn GetExitCodeProcess(
            hProcess: windows.HANDLE,
            lpExitCode: *windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *windows.HANDLE,
            hWritePipe: *windows.HANDLE,
            lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
            nSize: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreateNamedPipeW(
            lpName: windows.LPCWSTR,
            dwOpenMode: windows.DWORD,
            dwPipeMode: windows.DWORD,
            nMaxInstances: windows.DWORD,
            nOutBufferSize: windows.DWORD,
            nInBufferSize: windows.DWORD,
            nDefaultTimeOut: windows.DWORD,
            lpSecurityAttributes: ?*const windows.SECURITY_ATTRIBUTES,
        ) callconv(.winapi) windows.HANDLE;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: windows.LPCWSTR,
            dwDesiredAccess: windows.DWORD,
            dwShareMode: windows.DWORD,
            lpSecurityAttributes: ?*const windows.SECURITY_ATTRIBUTES,
            dwCreationDisposition: windows.DWORD,
            dwFlagsAndAttributes: windows.DWORD,
            hTemplateFile: ?windows.HANDLE,
        ) callconv(.winapi) windows.HANDLE;
        pub extern "kernel32" fn ReadFile(
            hFile: windows.HANDLE,
            lpBuffer: windows.LPVOID,
            nNumberOfBytesToRead: windows.DWORD,
            lpNumberOfBytesRead: ?*windows.DWORD,
            lpOverlapped: ?*anyopaque,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CancelIoEx(
            hFile: windows.HANDLE,
            lpOverlapped: ?*anyopaque,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn SetHandleInformation(
            hObject: windows.HANDLE,
            dwMask: windows.DWORD,
            dwFlags: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: windows.COORD,
            hInput: windows.HANDLE,
            hOutput: windows.HANDLE,
            dwFlags: windows.DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: windows.DWORD,
            dwFlags: windows.DWORD,
            lpSize: *windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: windows.DWORD,
            Attribute: windows.DWORD_PTR,
            lpValue: windows.PVOID,
            cbSize: windows.SIZE_T,
            lpPreviousValue: ?windows.PVOID,
            lpReturnSize: ?*windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: windows.HANDLE,
            lpBuffer: ?windows.LPVOID,
            nBufferSize: windows.DWORD,
            lpBytesRead: ?*windows.DWORD,
            lpTotalBytesAvail: ?*windows.DWORD,
            lpBytesLeftThisMessage: ?*windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?windows.LPWSTR,
            lpCommandLine: ?windows.LPWSTR,
            lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
            bInheritHandles: windows.BOOL,
            dwCreationFlags: windows.DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?windows.LPWSTR,
            lpStartupInfo: *windows.STARTUPINFOW,
            lpProcessInformation: *PROCESS_INFORMATION,
        ) callconv(.winapi) windows.BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: windows.LPSTR,
            nSize: *windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: windows.DWORD,
            lpBuffer: windows.LPWSTR,
        ) callconv(.winapi) windows.DWORD;
        pub extern "kernel32" fn VirtualAlloc(
            lpAddress: ?windows.LPVOID,
            dwSize: windows.SIZE_T,
            flAllocationType: windows.DWORD,
            flProtect: windows.DWORD,
        ) callconv(.winapi) ?windows.LPVOID;
        pub extern "kernel32" fn VirtualFree(
            lpAddress: windows.LPVOID,
            dwSize: windows.SIZE_T,
            dwFreeType: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
    };

    pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
    pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
    pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
    pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;

    pub const ProcThreadAttributeNumber = enum(windows.DWORD) {
        ProcThreadAttributePseudoConsole = 22,
        _,
    };

    /// Corresponds to the ProcThreadAttributeValue define in WinBase.h
    pub fn ProcThreadAttributeValue(
        comptime attribute: ProcThreadAttributeNumber,
        comptime thread: bool,
        comptime input: bool,
        comptime additive: bool,
    ) windows.DWORD {
        return (@intFromEnum(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
            (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
            (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
            (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
    }

    pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(.ProcThreadAttributePseudoConsole, false, true, false);
};
