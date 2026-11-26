//! A sampling profiler for this process, for profiling builds only
//! (`zig build -Dprofile-sampler=true`, Windows). A thread suspends each
//! other thread of the process every few milliseconds, records its
//! instruction pointer and unwinds its stack with the unwind tables (no
//! frame pointers needed), then resumes it. Only threads of this process
//! are touched. On `stop` the addresses are resolved from the PDB and
//! written as `<prefix>.<pid>.folded` and `<prefix>.<pid>.txt` (see
//! ranking.zig). Only samples of threads that used CPU since their last
//! sample count; the others are waiting.

const std = @import("std");
const sysinfo = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const ranking = @import("ranking.zig");
const symbols = @import("symbols.zig");

const max_depth = 96;
const interval_ms = 3;
const refresh_every = 40;

const Handle = windows.HANDLE;
const ThreadEntry = extern struct {
    size: u32,
    usage: u32,
    thread_id: u32,
    owner: u32,
    base_pri: i32,
    delta_pri: i32,
    flags: u32,
};
extern "kernel32" fn OpenThread(access: u32, inherit: i32, id: u32) callconv(.winapi) ?Handle;
extern "kernel32" fn SuspendThread(h: Handle) callconv(.winapi) u32;
extern "kernel32" fn ResumeThread(h: Handle) callconv(.winapi) u32;
extern "kernel32" fn GetThreadContext(h: Handle, c: *windows.CONTEXT) callconv(.winapi) i32;
extern "kernel32" fn QueryThreadCycleTime(h: Handle, cycles: *u64) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: Handle) callconv(.winapi) i32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) ?Handle;
extern "kernel32" fn Thread32First(s: Handle, e: *ThreadEntry) callconv(.winapi) i32;
extern "kernel32" fn Thread32Next(s: Handle, e: *ThreadEntry) callconv(.winapi) i32;
extern "winmm" fn timeBeginPeriod(ms: u32) callconv(.winapi) u32;
extern "winmm" fn timeEndPeriod(ms: u32) callconv(.winapi) u32;

// suspend/resume, get context, query information
const thread_access = 0x2 | 0x8 | 0x40;
// amd64 control and integer registers
const context_flags = 0x100003;

const Tracked = struct { id: u32, handle: Handle, cycles: u64 = 0 };

pub const Sampler = struct {
    gpa: Allocator,
    io: Io,
    prefix: []const u8,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    frames: std.ArrayList(usize) = .empty,
    /// The depth of each sample, in `frames` order
    depths: std.ArrayList(u8) = .empty,

    /// Starts sampling; `prefix` is the start of the output file names
    pub fn start(gpa: Allocator, io: Io, prefix: []const u8) !*Sampler {
        if (sysinfo.target.os.tag != .windows or sysinfo.target.cpu.arch != .x86_64) return error.Unsupported;
        const self = try gpa.create(Sampler);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .prefix = try gpa.dupe(u8, prefix), .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Ends sampling and writes the reports
    pub fn stop(self: *Sampler) void {
        self.stopping.store(true, .release);
        self.thread.join();
        self.write() catch |e| std.debug.print("profile: cannot write the report: {s}\n", .{@errorName(e)});
        self.frames.deinit(self.gpa);
        self.depths.deinit(self.gpa);
        self.gpa.free(self.prefix);
        self.gpa.destroy(self);
    }

    fn run(self: *Sampler) void {
        _ = timeBeginPeriod(1);
        defer _ = timeEndPeriod(1);
        const me = windows.GetCurrentThreadId();
        var tracked: std.ArrayList(Tracked) = .empty;
        defer {
            for (tracked.items) |t| _ = CloseHandle(t.handle);
            tracked.deinit(self.gpa);
        }
        var tick: usize = 0;
        while (!self.stopping.load(.acquire)) : (tick += 1) {
            if (tick % refresh_every == 0) self.refresh(&tracked, me) catch {};
            for (tracked.items) |*t| self.sample(t) catch {};
            Sleep(interval_ms);
        }
    }

    /// Adds the threads that appeared since the last refresh
    fn refresh(self: *Sampler, tracked: *std.ArrayList(Tracked), me: u32) !void {
        const snap = CreateToolhelp32Snapshot(0x4, 0) orelse return;
        defer _ = CloseHandle(snap);
        const pid = GetCurrentProcessId();
        var e: ThreadEntry = undefined;
        e.size = @sizeOf(ThreadEntry);
        var ok = Thread32First(snap, &e) != 0;
        while (ok) : (ok = Thread32Next(snap, &e) != 0) {
            if (e.owner != pid or e.thread_id == me) continue;
            var known = false;
            for (tracked.items) |t| known = known or t.id == e.thread_id;
            if (known) continue;
            const h = OpenThread(thread_access, 0, e.thread_id) orelse continue;
            tracked.append(self.gpa, .{ .id = e.thread_id, .handle = h }) catch {
                _ = CloseHandle(h);
                return error.OutOfMemory;
            };
        }
    }

    /// Records one sample of `t` when it used CPU since the last one. The
    /// thread is stopped only while its registers and stack are read: no
    /// allocation and no lock of ours in between.
    fn sample(self: *Sampler, t: *Tracked) !void {
        try self.frames.ensureUnusedCapacity(self.gpa, max_depth);
        try self.depths.ensureUnusedCapacity(self.gpa, 1);
        var cycles: u64 = 0;
        if (QueryThreadCycleTime(t.handle, &cycles) == 0) return;
        const busy = cycles != t.cycles;
        t.cycles = cycles;
        if (!busy) return;
        var buf: [max_depth]usize = undefined;
        var n: usize = 0;
        if (SuspendThread(t.handle) == std.math.maxInt(u32)) return;
        var ctx = std.mem.zeroes(windows.CONTEXT);
        ctx.ContextFlags = context_flags;
        if (GetThreadContext(t.handle, &ctx) != 0) n = unwind(&ctx, &buf);
        _ = ResumeThread(t.handle);
        if (n == 0) return;
        self.frames.appendSliceAssumeCapacity(buf[0..n]);
        self.depths.appendAssumeCapacity(@intCast(n));
    }

    fn write(self: *Sampler) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var names: std.AutoHashMapUnmanaged(usize, []const u8) = .empty;
        var prof: ranking.Profile = .init(self.gpa);
        defer prof.deinit();
        var stack: std.ArrayList([]const u8) = .empty;
        var at: usize = 0;
        for (self.depths.items) |depth| {
            stack.clearRetainingCapacity();
            for (self.frames.items[at..][0..depth], 0..) |addr, i| {
                const key = if (i == 0) addr else addr -| 1;
                const gop = try names.getOrPut(arena, key);
                if (!gop.found_existing) gop.value_ptr.* = try symbols.name(self.io, arena, addr, i != 0);
                try stack.append(arena, gop.value_ptr.*);
            }
            at += depth;
            try prof.add(stack.items);
        }
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try prof.writeFolded(&out.writer);
        try self.save(arena, ".folded", out.written());
        out.clearRetainingCapacity();
        try prof.writeRanking(arena, &out.writer, 80);
        try self.save(arena, ".txt", out.written());
    }

    fn save(self: *Sampler, arena: Allocator, ext: []const u8, data: []const u8) !void {
        const path = try arena.print("{s}.{d}{s}", .{ self.prefix, GetCurrentProcessId(), ext });
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data });
    }
};

/// Fills `buf` with the code addresses of the stack of `ctx`, innermost
/// first, by the unwind tables; stops at the end or an implausible frame.
fn unwind(ctx: *windows.CONTEXT, buf: []usize) usize {
    var history = std.mem.zeroes(windows.UNWIND_HISTORY_TABLE);
    const sp0 = ctx.getRegs().sp;
    var n: usize = 0;
    while (n < buf.len) {
        const regs = ctx.getRegs();
        if (regs.ip == 0) break;
        buf[n] = regs.ip;
        n += 1;
        const pc = if (n == 1) regs.ip else regs.ip -| 1;
        var base: usize = undefined;
        if (windows.ntdll.RtlLookupFunctionEntry(pc, &base, &history)) |entry| {
            var handler: ?*anyopaque = null;
            var frame: usize = undefined;
            _ = windows.ntdll.RtlVirtualUnwind(windows.UNW_FLAG_NHANDLER, base, pc, entry, ctx, &handler, &frame, null);
        } else {
            ctx.setIp(@as(*const usize, @ptrFromInt(regs.sp)).*);
            ctx.setSp(regs.sp + @sizeOf(usize));
        }
        const next = ctx.getRegs().sp;
        if (next <= regs.sp or next - sp0 > (512 << 20)) break;
    }
    return n;
}
