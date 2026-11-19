//! Running the programs whose output zfls reads (the compiler, fypp, the
//! formatters, fortitude, Codee): with an input on stdin, for at most a
//! time, and with the processes they start. Each one runs in a job object
//! (Windows) or process group (elsewhere) of its own, which is killed on a
//! timeout, an error, or when the thread that waits for it is stopped
//! (`Running.stop`, at a server shutdown): a compiler driver's compiler
//! proper (gfortran's f951, ifx's xfortcom) or a launcher's interpreter
//! does not stay behind.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const is_windows = builtin.target.os.tag == .windows;

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    /// Windows: the whole exit status, of which `term` has the low byte
    /// only (`0xC0000135`, a DLL not found)
    status: ?u32 = null,
};

pub const Options = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    /// Written to its stdin, which is then closed; null: no stdin
    input: ?[]const u8 = null,
    timeout: Io.Timeout = .none,
    /// Where another thread can stop it
    running: ?*Running = null,
};

/// The program a thread is running, for another thread to stop
pub const Running = struct {
    mutex: Io.Mutex = .init,
    group: ?Group = null,
    stopped: bool = false,

    /// Kills the program running and those it started, and any started
    /// afterwards
    pub fn stop(r: *Running, io: Io) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.stopped = true;
        if (r.group) |g| g.kill();
    }

    /// Records `g` as running; false when stopped already
    fn start(r: *Running, io: Io, g: Group) bool {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        if (r.stopped) return false;
        r.group = g;
        return true;
    }

    fn end(r: *Running, io: Io) void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.group = null;
    }
};

/// A program and the processes it starts
const Group = struct {
    /// The job object (Windows; null when the process could not be put in
    /// one), or the process group, whose id is the program's pid
    id: if (is_windows) ?std.os.windows.HANDLE else std.posix.pid_t,

    /// Puts the program, started suspended on Windows (and in a process
    /// group of its own elsewhere), in a group, and lets it run
    fn adopt(child: *const std.process.Child) Group {
        if (!is_windows) return .{ .id = child.id.? };
        const job = win.CreateJobObjectW(null, null);
        if (job) |j| {
            var info = std.mem.zeroes(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            const ok = win.SetInformationJobObject(j, win.JobObjectExtendedLimitInformation, &info, @sizeOf(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) != 0 and
                win.AssignProcessToJobObject(j, child.id.?) != 0;
            if (!ok) {
                std.os.windows.CloseHandle(j);
                _ = win.ResumeThread(child.thread_handle);
                return .{ .id = null };
            }
        }
        _ = win.ResumeThread(child.thread_handle);
        return .{ .id = job };
    }

    fn kill(g: Group) void {
        if (is_windows) {
            if (g.id) |j| _ = win.TerminateJobObject(j, 1);
        } else std.posix.kill(-g.id, .KILL) catch {};
    }

    /// Done with it: on Windows the processes still in the job end
    fn close(g: Group) void {
        if (is_windows) if (g.id) |j| std.os.windows.CloseHandle(j);
    }
};

/// Runs `o.argv` to its end, or for `o.timeout` (`error.Timeout`), and
/// returns its output. The input is written on a thread of its own, so that
/// a program that writes before it has read all of it cannot block on a
/// full pipe.
pub fn run(a: Allocator, io: Io, o: Options) !Output {
    var writer: ?std.Thread = null;
    defer if (writer) |t| t.join();
    var child = try std.process.spawn(io, .{
        .argv = o.argv,
        .cwd = if (o.cwd) |d| .{ .path = d } else .inherit,
        .environ_map = o.environ_map,
        .create_no_window = true,
        .stdin = if (o.input != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // its own process group, whose id is its pid
        .pgid = if (is_windows) null else 0,
        // into the job before it can start anything
        .start_suspended = is_windows,
    });
    // a child still running (after an error) is killed before the writer
    // is joined, which ends its write
    defer child.kill(io);
    const group = Group.adopt(&child);
    defer group.close();
    if (o.running) |r| {
        if (!r.start(io, group)) {
            group.kill();
            return error.Stopped;
        }
    }
    defer if (o.running) |r| r.end(io);

    if (o.input) |input| {
        const stdin = child.stdin.?;
        child.stdin = null;
        writer = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, writeInput, .{ io, stdin, input }) catch |e| {
            stdin.close(io);
            return e;
        };
    }
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    // before the reads are given up: a process still writing would hold
    // them
    errdefer group.kill();
    const deadline = o.timeout.toDeadline(io);
    while (multi.fill(64, deadline)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();
    const status = if (is_windows) win.exitStatus(child.id.?) else null;
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try multi.toOwnedSlice(0), .stderr = try multi.toOwnedSlice(1), .status = status };
}

fn writeInput(io: Io, file: Io.File, input: []const u8) void {
    defer file.close(io);
    // a program that ends without reading all of it: its output tells
    file.writeStreamingAll(io, input) catch {};
}

/// How a program ended, for a message: `exit code 3`, `exit status
/// 0xC0000135 (a DLL it needs was not found)`, `signal SEGV`
pub fn describeExit(a: Allocator, out: Output) ![]const u8 {
    if (out.status) |s| if (s > 0xff) {
        const known: []const u8 = switch (s) {
            0xC0000135 => " (a DLL it needs was not found)",
            0xC0000139 => " (a procedure it needs was not found in a DLL)",
            else => "",
        };
        return a.print("exit status 0x{X}{s}", .{ s, known });
    };
    return switch (out.term) {
        .exited => |code| a.print("exit code {d}", .{code}),
        .signal, .stopped => |sig| a.print("signal {t}", .{sig}),
        .unknown => |s| a.print("exit status 0x{X}", .{s}),
    };
}

/// A timeout of `s` seconds
pub fn seconds(s: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(s), .clock = .awake } };
}

const win = struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;

    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: i64,
        PerJobUserTimeLimit: i64,
        LimitFlags: u32,
        MinimumWorkingSetSize: usize,
        MaximumWorkingSetSize: usize,
        ActiveProcessLimit: u32,
        Affinity: usize,
        PriorityClass: u32,
        SchedulingClass: u32,
    };
    const IO_COUNTERS = extern struct {
        ReadOperationCount: u64,
        WriteOperationCount: u64,
        OtherOperationCount: u64,
        ReadTransferCount: u64,
        WriteTransferCount: u64,
        OtherTransferCount: u64,
    };
    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
        IoInfo: IO_COUNTERS,
        ProcessMemoryLimit: usize,
        JobMemoryLimit: usize,
        PeakProcessMemoryUsed: usize,
        PeakJobMemoryUsed: usize,
    };
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
    const JobObjectExtendedLimitInformation: i32 = 9;

    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: i32, info: *const anyopaque, len: u32) callconv(.winapi) i32;
    extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn TerminateJobObject(job: HANDLE, code: u32) callconv(.winapi) i32;
    extern "kernel32" fn ResumeThread(thread: HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) i32;

    /// The exit status of a process, once it has ended
    fn exitStatus(process: HANDLE) ?u32 {
        if (WaitForSingleObject(process, 0xFFFFFFFF) != 0) return null;
        var code: u32 = 0;
        return if (GetExitCodeProcess(process, &code) != 0) code else null;
    }
};

test "a timeout kills the program and the processes it started" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    // the program starts one that writes `late` after 3 seconds, then
    // waits longer itself
    const script = if (is_windows) "slow.cmd" else "slow.sh";
    try tmp.dir.writeFile(io, .{ .sub_path = script, .data = if (is_windows)
        "@echo off\r\nstart /b cmd /c \"ping -n 4 127.0.0.1 >nul & echo x> late\"\r\nping -n 30 127.0.0.1 >nul\r\n"
    else
        "#!/bin/sh\n(sleep 3; echo x > late) &\nsleep 30\n" });
    if (!is_windows) try tmp.dir.setFilePermissions(io, script, .executable_file, .{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const exe = try std.Io.Dir.path.join(a, &.{ dir, script });
    const start = Io.Clock.awake.now(io).nanoseconds;
    try testing.expectError(error.Timeout, run(a, io, .{ .argv = &.{exe}, .cwd = dir, .timeout = seconds(1) }));
    // stopped at the timeout, not when the program would have ended
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - start < 20 * std.time.ns_per_s);
    io.sleep(.fromSeconds(5), .awake) catch {};
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "late", .{}));
}

test "the input on stdin, the output and the exit code" {
    const testing = std.testing;
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv: []const []const u8 = if (is_windows) &.{ "cmd", "/c", "more" } else &.{"cat"};
    const r = try run(a, io, .{ .argv = argv, .input = "abc\n", .timeout = seconds(30) });
    try testing.expect(r.term.success());
    try testing.expectEqualStrings("abc", std.mem.trim(u8, r.stdout, " \r\n"));
}

test "a stopped thread starts no program" {
    const io = std.testing.io;
    var r: Running = .{};
    r.stop(io);
    const argv: []const []const u8 = if (is_windows) &.{ "cmd", "/c", "exit" } else &.{"true"};
    try std.testing.expectError(error.Stopped, run(std.testing.allocator, io, .{ .argv = argv, .running = &r }));
}

test "how a program ended, for a message" {
    const a = std.testing.allocator;
    const cases = [_]struct { out: Output, want: []const u8 }{
        .{ .out = .{ .term = .{ .exited = 0x35 }, .stdout = &.{}, .stderr = &.{}, .status = 0xC0000135 }, .want = "exit status 0xC0000135 (a DLL it needs was not found)" },
        .{ .out = .{ .term = .{ .exited = 0x39 }, .stdout = &.{}, .stderr = &.{}, .status = 0xC0000139 }, .want = "exit status 0xC0000139 (a procedure it needs was not found in a DLL)" },
        .{ .out = .{ .term = .{ .exited = 0x34 }, .stdout = &.{}, .stderr = &.{}, .status = 0xC0001234 }, .want = "exit status 0xC0001234" },
        .{ .out = .{ .term = .{ .exited = 3 }, .stdout = &.{}, .stderr = &.{}, .status = 3 }, .want = "exit code 3" },
        .{ .out = .{ .term = .{ .exited = 1 }, .stdout = &.{}, .stderr = &.{} }, .want = "exit code 1" },
    };
    for (cases) |c| {
        const got = try describeExit(a, c.out);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "the whole exit status on Windows" {
    if (!is_windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try run(arena.allocator(), std.testing.io, .{ .argv = &.{ "cmd", "/c", "exit", "-1073741515" }, .timeout = seconds(30) });
    try std.testing.expectEqual(@as(?u32, 0xC0000135), r.status);
    try std.testing.expect(!r.term.success());
}
