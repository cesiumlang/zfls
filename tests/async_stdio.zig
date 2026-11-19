//! zfls with standard streams opened for asynchronous (overlapped) I/O
//! (`zig build test-stdio`, Windows only; part of `zig build test` there).
//!
//! MSYS2 and Cygwin programs (Git Bash's `zfls ... | wc`) and Node.js with
//! `stdio: "overlapped"` hand such pipes to the server. A write to a full
//! one, or a read from an empty one, is then pending and finishes later;
//! zfls lost its output there. This starts zfls with such pipes, reads its
//! output late, so that the pipe fills, and feeds its input slowly, so that
//! the pipe is empty, and compares the result with a run on ordinary
//! (synchronous) pipes:
//!
//! - the `--debug_symbols` output of a large file, byte for byte;
//! - an LSP session with large responses: each response, and the exit code.
//!
//! It also checks that the server ends after `exit` when its input is left
//! open, with a message cut off after it (the read of its body is then
//! canceled), on either kind of pipe; and that no run has a report of the
//! debug build's allocator (a leak) or a panic on its standard error.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zfls = @import("zfls");
const lsp = @import("lsp_client");
const TestPipe = zfls.stdio.TestPipe;
const windows = std.os.windows;

const is_windows = builtin.target.os.tag == .windows;

extern "kernel32" fn SetHandleInformation(h: windows.HANDLE, mask: u32, flags: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(h: windows.HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(h: windows.HANDLE, code: *u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn TerminateProcess(h: windows.HANDLE, code: u32) callconv(.winapi) windows.BOOL;
const HANDLE_FLAG_INHERIT = 1;

/// The subroutines of the source file: enough for an output of several
/// pipe buffers (MSYS2's hold 64 KiB)
const subroutines = 2500;
const pipe_size = 64 * 1024;
/// How long the output is left unread
const read_delay: Io.Duration = .fromMilliseconds(400);
/// How long a run may take
const run_timeout_ms = 120_000;
/// How long the server may take to end after `exit` with its input open
const keep_open_timeout_ms = 20_000;

/// What a debug build writes to standard error about memory errors, and
/// a panic
const allocator_reports = [_][]const u8{ "panic", "leaked", "double free", "invalid free", "segmentation fault" };

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u32,

    /// The allocator's report or the panic on standard error, if any
    fn report(r: Result) ?[]const u8 {
        for (allocator_reports) |w| if (std.ascii.findIgnoreCase(r.stderr, w) != null) return w;
        return null;
    }
};

const Feeder = struct {
    io: Io,
    file: Io.File,
    data: []const u8,
    /// Sleep between the pieces, so that the reader finds the pipe empty
    slow: bool,
    /// The input is left open (closed by `run` once the process ended)
    keep_open: bool,

    fn run(self: *Feeder) void {
        var at: usize = 0;
        while (at < self.data.len) {
            const n = @min(self.data.len - at, if (self.slow) @as(usize, 3000) else self.data.len);
            self.file.writeStreamingAll(self.io, self.data[at..][0..n]) catch break;
            at += n;
            if (self.slow) self.io.sleep(.fromMilliseconds(15), .awake) catch {};
        }
        if (!self.keep_open) self.file.close(self.io);
    }
};

/// Runs `argv` with `input` as its standard input and returns what it wrote
/// to standard output and standard error (a file in `tmp`). Its ends of the
/// two pipes are opened as `end` says; with `.overlapped` the output is read
/// late and the input fed slowly. With `keep_open` the input is not closed
/// before the process ends.
fn run(io: Io, a: Allocator, tmp: []const u8, argv: []const []const u8, input: []const u8, end: TestPipe.End, keep_open: bool) !Result {
    const overlapped = end == .overlapped;
    // ours: the reading end of its output, the writing end of its input
    const out = try TestPipe.open(.synchronous, end, pipe_size);
    const in = try TestPipe.open(end, .synchronous, pipe_size);
    const err_path = try Io.Dir.path.join(a, &.{ tmp, "stderr.txt" });
    const err_file = try Io.Dir.cwd().createFile(io, err_path, .{});
    for ([_]windows.HANDLE{ out.write.handle, in.read.handle, err_file.handle }) |h| {
        if (SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) == .FALSE) return error.HandleNotInheritable;
    }

    var cmd: std.ArrayList(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (std.mem.findScalar(u8, arg, '"') != null) return error.QuoteInArgument;
        try cmd.print(a, "{s}\"{s}\"", .{ if (i == 0) "" else " ", arg });
    }
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(a, cmd.items);
    var si = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    si.dwFlags = windows.STARTF_USESTDHANDLES;
    si.hStdInput = in.read.handle;
    si.hStdOutput = out.write.handle;
    si.hStdError = err_file.handle;
    var pi: windows.PROCESS.INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(null, cmd_w.ptr, null, null, .TRUE, .{ .create_no_window = true }, null, null, &si, &pi) == .FALSE)
        return error.ProcessNotStarted;
    windows.CloseHandle(pi.hThread);
    defer windows.CloseHandle(pi.hProcess);
    // the child has its own handles of its ends now
    out.write.close(io);
    in.read.close(io);
    err_file.close(io);

    var feeder: Feeder = .{ .io = io, .file = in.write, .data = input, .slow = overlapped, .keep_open = keep_open };
    const th = try std.Thread.spawn(.{}, Feeder.run, .{&feeder});
    // with the input open, a server that does not end would not close its
    // output either: its end is waited for first (its output is short)
    const hangs = keep_open and WaitForSingleObject(pi.hProcess, keep_open_timeout_ms) != 0;
    if (hangs) _ = TerminateProcess(pi.hProcess, 1);
    if (overlapped) io.sleep(read_delay, .awake) catch {};
    var buf: [4096]u8 = undefined;
    var reader = out.read.readerStreaming(io, &buf);
    var got: std.ArrayList(u8) = .empty;
    reader.interface.appendRemainingUnlimited(a, &got) catch {};
    out.read.close(io);

    var code: u32 = 0;
    if (hangs or WaitForSingleObject(pi.hProcess, run_timeout_ms) != 0) {
        _ = TerminateProcess(pi.hProcess, 1);
        th.join();
        if (keep_open) in.write.close(io);
        return error.ProcessHangs;
    }
    th.join();
    if (keep_open) in.write.close(io);
    if (GetExitCodeProcess(pi.hProcess, &code) == .FALSE) return error.NoExitCode;
    const err_text = try Io.Dir.cwd().readFileAlloc(io, err_path, a, .limited(1 << 24));
    return .{ .stdout = got.items, .stderr = err_text, .exit_code = code };
}

fn sourceText(a: Allocator) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..subroutines) |i| try text.print(a,
        \\      subroutine sub{d}(a, b)
        \\      integer a, b
        \\      a = b + {d}
        \\      b = a
        \\      end
        \\
    , .{ i, i });
    return text.items;
}

/// The messages of a session: `initialize`, the file opened, its symbols
/// asked for several times, `shutdown` and `exit`
fn session(a: Allocator, root: []const u8, file: []const u8, text: []const u8) ![]u8 {
    const opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    const root_uri = try zfls.paths.pathToUri(a, root);
    const uri = try zfls.paths.pathToUri(a, file);
    var out: std.ArrayList(u8) = .empty;
    const Doc = struct { uri: []const u8 };
    try out.appendSlice(a, try zfls.jsonrpc.frame(a, try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "initialize",
        .params = .{ .rootUri = root_uri, .capabilities = struct {}{} },
    }, opts)));
    try out.appendSlice(a, try zfls.jsonrpc.frame(a, try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .method = "initialized",
        .params = .{},
    }, opts)));
    try out.appendSlice(a, try zfls.jsonrpc.frame(a, try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didOpen",
        .params = .{ .textDocument = .{ .uri = uri, .languageId = "fortran", .version = 1, .text = text } },
    }, opts)));
    for (0..symbol_requests) |i| try out.appendSlice(a, try zfls.jsonrpc.frame(a, try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .id = first_symbol_id + i,
        .method = "textDocument/documentSymbol",
        .params = .{ .textDocument = Doc{ .uri = uri } },
    }, opts)));
    try out.appendSlice(a, try zfls.jsonrpc.frame(a, try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .id = shutdown_id,
        .method = "shutdown",
    }, opts)));
    try out.appendSlice(a, try zfls.jsonrpc.frame(a, try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .method = "exit",
    }, opts)));
    return out.items;
}

/// `initialize`, `shutdown` and `exit`, and then the start of a message
/// whose body does not follow
fn shortSession(a: Allocator, root: []const u8) ![]u8 {
    const opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, try zfls.jsonrpc.frame(a, try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "initialize",
        .params = .{ .rootUri = try zfls.paths.pathToUri(a, root), .capabilities = struct {}{} },
    }, opts)));
    try out.appendSlice(a, try zfls.jsonrpc.frame(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}"));
    try out.appendSlice(a, try zfls.jsonrpc.frame(a, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"));
    try out.appendSlice(a, "Content-Length: 1000\r\n\r\n{\"jsonrpc\":");
    return out.items;
}

const symbol_requests = 4;
const first_symbol_id = 2;
const shutdown_id = first_symbol_id + symbol_requests;

/// The responses in `stream` by request id (index 0 is unused); null for a
/// response that is not there
fn responses(a: Allocator, stream: []const u8) ![shutdown_id + 1]?[]const u8 {
    var found: [shutdown_id + 1]?[]const u8 = @splat(null);
    var r: Io.Reader = .fixed(stream);
    while (zfls.jsonrpc.readMessage(&r, a) catch null) |body| {
        const msg = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch continue;
        if (msg != .object or msg.object.get("method") != null) continue;
        const id = msg.object.get("id") orelse continue;
        if (id != .integer or id.integer < 1 or id.integer > shutdown_id) continue;
        found[@intCast(id.integer)] = body;
    }
    return found;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 3 or !std.mem.eql(u8, argv[1], "--zfls")) {
        std.debug.print("usage: async_stdio --zfls ZFLS.EXE\n", .{});
        return 2;
    }
    if (!is_windows) {
        std.debug.print("skipped: Windows only\n", .{});
        return 0;
    }
    const cwd = Io.Dir.cwd();
    const exe = try cwd.realPathFileAlloc(io, argv[2], a);
    const tmp = try lsp.tempDir(io, a, init.environ_map, "zfls-stdio-");
    defer cwd.deleteTree(io, tmp) catch {};
    const file = try Io.Dir.path.join(a, &.{ tmp, "big.F" });
    const text = try sourceText(a);
    try cwd.writeFile(io, .{ .sub_path = file, .data = text });

    var failures: usize = 0;
    var results: std.ArrayList(struct { what: []const u8, result: Result }) = .empty;

    // the debug output
    {
        const args = [_][]const u8{ exe, "--debug_symbols", "--debug_filepath", file, "--debug_rootpath", tmp };
        const want = try run(io, a, tmp, &args, "", .synchronous, false);
        const got = try run(io, a, tmp, &args, "", .overlapped, false);
        if (want.exit_code != 0 or want.stdout.len <= pipe_size) {
            std.debug.print("FAIL --debug_symbols on synchronous pipes: exit code {d}, {d} bytes (too few to fill a pipe)\n", .{ want.exit_code, want.stdout.len });
            failures += 1;
        } else if (got.exit_code != 0 or !std.mem.eql(u8, want.stdout, got.stdout)) {
            std.debug.print("FAIL --debug_symbols on overlapped pipes: exit code {d}, {d} of {d} bytes\n", .{ got.exit_code, got.stdout.len, want.stdout.len });
            failures += 1;
        } else std.debug.print("ok   --debug_symbols on overlapped pipes: {d} bytes\n", .{got.stdout.len});
        try results.append(a, .{ .what = "--debug_symbols on synchronous pipes", .result = want });
        try results.append(a, .{ .what = "--debug_symbols on overlapped pipes", .result = got });
    }

    // the language server
    {
        const args = [_][]const u8{exe};
        const input = try session(a, tmp, file, text);
        const want = try run(io, a, tmp, &args, input, .synchronous, false);
        const got = try run(io, a, tmp, &args, input, .overlapped, false);
        const want_responses = try responses(a, want.stdout);
        const got_responses = try responses(a, got.stdout);
        var reference_ok = want.exit_code == 0 and want.stdout.len > pipe_size;
        for (want_responses[1..]) |w| reference_ok = reference_ok and w != null;
        if (!reference_ok) {
            std.debug.print("FAIL server on synchronous pipes: exit code {d}, {d} bytes (too few to fill a pipe, or a response is missing)\n", .{ want.exit_code, want.stdout.len });
            failures += 1;
        } else {
            var ok = got.exit_code == 0;
            for (want_responses[1..], got_responses[1..], 1..) |w, g, id| {
                if (g != null and std.mem.eql(u8, w.?, g.?)) continue;
                std.debug.print("     request {d}: {d} of {d} bytes\n", .{ id, if (g) |x| x.len else 0, w.?.len });
                ok = false;
            }
            if (ok) {
                std.debug.print("ok   server on overlapped pipes: {d} bytes, {d} responses\n", .{ got.stdout.len, shutdown_id });
            } else {
                std.debug.print("FAIL server on overlapped pipes: exit code {d}, {d} bytes written ({d} on synchronous pipes)\n", .{ got.exit_code, got.stdout.len, want.stdout.len });
                failures += 1;
            }
        }
        try results.append(a, .{ .what = "server on synchronous pipes", .result = want });
        try results.append(a, .{ .what = "server on overlapped pipes", .result = got });
    }

    // `exit` with the input left open and a message cut off after it
    for ([_]TestPipe.End{ .synchronous, .overlapped }) |end| {
        const args = [_][]const u8{exe};
        const input = try shortSession(a, tmp);
        const what = try a.print("server ends after exit with its input open, on {t} pipes", .{end});
        const got = run(io, a, tmp, &args, input, end, true) catch |e| {
            std.debug.print("FAIL {s}: {t}\n", .{ what, e });
            failures += 1;
            continue;
        };
        if (got.exit_code != 0) {
            std.debug.print("FAIL {s}: exit code {d}\n", .{ what, got.exit_code });
            failures += 1;
        } else std.debug.print("ok   {s}\n", .{what});
        try results.append(a, .{ .what = what, .result = got });
    }

    for (results.items) |r| if (r.result.report()) |w| {
        std.debug.print("FAIL {s}: \"{s}\" on standard error:\n{s}\n", .{ r.what, w, r.result.stderr });
        failures += 1;
    };

    return if (failures == 0) 0 else 1;
}

test "the responses of a stream are found by id" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stream: std.ArrayList(u8) = .empty;
    try stream.appendSlice(a, try zfls.jsonrpc.frame(a, "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"id\":3}"));
    try stream.appendSlice(a, try zfls.jsonrpc.frame(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}"));
    // cut off, as a lost write leaves it
    try stream.appendSlice(a, (try zfls.jsonrpc.frame(a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":null}"))[0..40]);
    const found = try responses(a, stream.items);
    try std.testing.expect(found[2] != null);
    try std.testing.expect(found[3] == null);
    try std.testing.expect(found[4] == null);
}

test "the session's messages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (is_windows) "C:\\w" else "/w";
    const file = if (is_windows) "C:\\w\\big.F" else "/w/big.F";
    const input = try session(a, root, file, try sourceText(a));
    var r: Io.Reader = .fixed(input);
    var n: usize = 0;
    while (try zfls.jsonrpc.readMessage(&r, a)) |_| n += 1;
    try std.testing.expectEqual(5 + symbol_requests, n);
}
