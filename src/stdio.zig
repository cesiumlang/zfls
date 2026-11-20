//! The process's standard streams.
//!
//! `std.Io.File.stdin()`, `stdout()` and `stderr()` take the handles to be
//! opened for synchronous I/O. On Windows a parent can hand over a pipe
//! opened for asynchronous (overlapped) I/O instead: MSYS2 and Cygwin
//! programs do (Git Bash's `zfls ... | wc`), and Node.js with
//! `stdio: "overlapped"`. On such a handle a write to a full pipe, or a
//! read from an empty one, returns `STATUS_PENDING` and finishes later,
//! which the standard library's synchronous path does not expect (it is
//! `unreachable` there: in a release build the output was dropped).
//!
//! The functions here ask the handle how it was opened and set the file's
//! `nonblocking` flag to match, which makes the standard library wait for
//! the operation to complete. Use them, not `std.Io.File`'s, for anything
//! read from or written to the standard streams.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const windows = std.os.windows;

const is_windows = builtin.target.os.tag == .windows;

pub fn stdin() Io.File {
    return adapt(Io.File.stdin());
}

pub fn stdout() Io.File {
    return adapt(Io.File.stdout());
}

pub fn stderr() Io.File {
    return adapt(Io.File.stderr());
}

/// `file` with the `nonblocking` flag that its handle needs
pub fn adapt(file: Io.File) Io.File {
    if (!is_windows) return file;
    var f = file;
    f.flags.nonblocking = isAsynchronous(file.handle);
    return f;
}

// FILE_MODE_INFORMATION's flags (wdm.h)
const FILE_SYNCHRONOUS_IO_ALERT: windows.ULONG = 0x10;
const FILE_SYNCHRONOUS_IO_NONALERT: windows.ULONG = 0x20;

/// Whether `handle` was opened for asynchronous (overlapped) I/O. False
/// when the handle cannot be asked (none, or not a file).
fn isAsynchronous(handle: windows.HANDLE) bool {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var mode: windows.ULONG = 0;
    const status = windows.ntdll.NtQueryInformationFile(handle, &iosb, &mode, @sizeOf(windows.ULONG), .Mode);
    if (status != .SUCCESS) return false;
    return mode & (FILE_SYNCHRONOUS_IO_ALERT | FILE_SYNCHRONOUS_IO_NONALERT) == 0;
}

// --------------------------------------------------------------------------
// Tests (Windows): a pipe opened for overlapped I/O, as MSYS2 makes them

const testing = std.testing;

extern "kernel32" fn CreateNamedPipeW(
    name: [*:0]const u16,
    open_mode: u32,
    pipe_mode: u32,
    max_instances: u32,
    out_buffer_size: u32,
    in_buffer_size: u32,
    default_timeout: u32,
    security: ?*anyopaque,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: u32,
    share: u32,
    security: ?*anyopaque,
    disposition: u32,
    flags: u32,
    template: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

const PIPE_ACCESS_INBOUND = 0x1;
const PIPE_ACCESS_OUTBOUND = 0x2;
const FILE_FLAG_OVERLAPPED = 0x40000000;
const GENERIC_READ = 0x80000000;
const GENERIC_WRITE = 0x40000000;
const OPEN_EXISTING = 3;

/// A pipe for tests whose two ends are opened as wanted
pub const TestPipe = struct {
    read: Io.File,
    write: Io.File,

    pub const End = enum { synchronous, overlapped };

    var count: std.atomic.Value(u32) = .init(0);

    /// A pipe of `buffer_size` bytes. The files have the `nonblocking`
    /// flag of `std.Io.File.stdout()` (false), whatever their handles are:
    /// pass them through `adapt`.
    pub fn open(read_end: End, write_end: End, buffer_size: u32) !TestPipe {
        var name_buf: [96]u8 = undefined;
        const name = try std.mem.print(&name_buf, "\\\\.\\pipe\\zfls-test-{d}-{d}", .{ GetCurrentProcessId(), count.fetchAdd(1, .monotonic) });
        var wname: [96:0]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&wname, name);
        wname[n] = 0;
        // the server end is the reading one
        const server = CreateNamedPipeW(
            &wname,
            PIPE_ACCESS_INBOUND | (if (read_end == .overlapped) @as(u32, FILE_FLAG_OVERLAPPED) else 0),
            0, // a byte stream that blocks (no PIPE_NOWAIT)
            1,
            buffer_size,
            buffer_size,
            0,
            null,
        );
        if (server == windows.INVALID_HANDLE_VALUE) return error.PipeNotCreated;
        errdefer windows.CloseHandle(server);
        const client = CreateFileW(
            &wname,
            GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            if (write_end == .overlapped) FILE_FLAG_OVERLAPPED else 0,
            null,
        );
        if (client == windows.INVALID_HANDLE_VALUE) return error.PipeNotOpened;
        return .{
            .read = .{ .handle = server, .flags = .{ .nonblocking = false } },
            .write = .{ .handle = client, .flags = .{ .nonblocking = false } },
        };
    }
};

fn testPattern(buf: []u8) void {
    for (buf, 0..) |*c, i| c.* = @truncate(i *% 31 +% (i >> 8));
}

const SlowReader = struct {
    file: Io.File,
    got: []u8,
    len: usize = 0,
    failed: bool = false,

    /// Reads to the end of the stream, starting late so that the pipe is
    /// full by then
    fn run(self: *SlowReader) void {
        const io = testing.io;
        io.sleep(.fromMilliseconds(150), .awake) catch {};
        var buf: [4096]u8 = undefined;
        var r = self.file.readerStreaming(io, &buf);
        while (self.len < self.got.len) {
            const n = r.interface.readSliceShort(self.got[self.len..]) catch {
                self.failed = true;
                return;
            };
            if (n == 0) return;
            self.len += n;
        }
    }
};

test "a write to a full overlapped pipe waits for the reader" {
    if (!is_windows) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    const size = 512 * 1024;
    const sent = try gpa.alloc(u8, size);
    defer gpa.free(sent);
    testPattern(sent);
    const got = try gpa.alloc(u8, size);
    defer gpa.free(got);

    const pipe = try TestPipe.open(.synchronous, .overlapped, 4096);
    try testing.expect(isAsynchronous(pipe.write.handle));
    try testing.expect(!isAsynchronous(pipe.read.handle));
    var reader: SlowReader = .{ .file = adapt(pipe.read), .got = got };
    const th = try std.Thread.spawn(.{}, SlowReader.run, .{&reader});
    const out = adapt(pipe.write);
    try testing.expect(out.flags.nonblocking);
    // as the server writes: a header and a body, many times
    var at: usize = 0;
    var err: ?anyerror = null;
    while (at < size) {
        const n = @min(size - at, 1 + at % 9000);
        out.writeStreamingAll(io, sent[at..][0..n]) catch |e| {
            err = e;
            break;
        };
        at += n;
    }
    out.close(io);
    th.join();
    pipe.read.close(io);
    if (err) |e| return e;
    try testing.expect(!reader.failed);
    try testing.expectEqual(size, reader.len);
    try testing.expect(std.mem.eql(u8, sent, got));
}

const SlowWriter = struct {
    file: Io.File,
    data: []const u8,

    fn run(self: *SlowWriter) void {
        const io = testing.io;
        var at: usize = 0;
        while (at < self.data.len) {
            io.sleep(.fromMilliseconds(20), .awake) catch {};
            const n = @min(self.data.len - at, 5000);
            self.file.writeStreamingAll(io, self.data[at..][0..n]) catch return;
            at += n;
        }
        self.file.close(io);
    }
};

test "a read from an empty overlapped pipe waits for the writer" {
    if (!is_windows) return error.SkipZigTest;
    const io = testing.io;
    const gpa = testing.allocator;
    const size = 40 * 1024;
    const sent = try gpa.alloc(u8, size);
    defer gpa.free(sent);
    testPattern(sent);
    const got = try gpa.alloc(u8, size);
    defer gpa.free(got);

    const pipe = try TestPipe.open(.overlapped, .synchronous, 4096);
    try testing.expect(isAsynchronous(pipe.read.handle));
    var writer: SlowWriter = .{ .file = pipe.write, .data = sent };
    const th = try std.Thread.spawn(.{}, SlowWriter.run, .{&writer});
    var buf: [4096]u8 = undefined;
    var r = adapt(pipe.read).readerStreaming(io, &buf);
    const result = r.interface.readSliceAll(got);
    th.join();
    pipe.read.close(io);
    try result;
    try testing.expect(std.mem.eql(u8, sent, got));
}

test "the standard streams of the test runner can be asked" {
    // whatever they are (a console, a pipe, nothing): no failure
    _ = stdin();
    _ = stdout();
    _ = stderr();
}
