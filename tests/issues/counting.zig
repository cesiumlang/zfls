//! An allocator that counts what goes through it: the allocations and the
//! bytes asked for. The server's work on a scenario is measured in these
//! rather than in seconds (tests/issues/allocation_counts.zig, `zig build
//! bench`): they do not change with the machine's load.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// The allocations by the call stack that asked (`ZFLS_ALLOC_SITES` names a
/// phase of allocation_counts.zig whose top sites are printed)
pub const Sites = struct {
    a: Allocator,
    busy: std.atomic.Value(bool) = .init(false),
    map: std.AutoHashMapUnmanaged(u64, Site) = .empty,

    const depth = 12;
    pub const Site = struct { allocs: u64 = 0, bytes: u64 = 0, frames: [depth]usize = undefined, n: usize = 0 };

    fn add(s: *Sites, len: usize) void {
        var buf: [depth]usize = undefined;
        const trace = std.debug.captureCurrentStackTrace(.{}, &buf);
        const frames = trace.return_addresses;
        // (the first frames are the allocator's own)
        const skip = @min(3, frames.len);
        const used = frames[skip..];
        var key: u64 = 0;
        for (used) |f| key = key *% 0x100000001b3 ^ f;
        while (s.busy.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer s.busy.store(false, .release);
        const e = s.map.getOrPut(s.a, key) catch return;
        if (!e.found_existing) {
            e.value_ptr.* = .{ .n = used.len };
            @memcpy(e.value_ptr.frames[0..used.len], used);
        }
        e.value_ptr.allocs += 1;
        e.value_ptr.bytes += len;
    }

    /// Prints the `n` sites that asked for the most bytes, and forgets them
    pub fn dump(s: *Sites, name: []const u8, n: usize) void {
        var list: std.ArrayList(Site) = .empty;
        defer list.deinit(s.a);
        var it = s.map.valueIterator();
        while (it.next()) |site| list.append(s.a, site.*) catch return;
        std.mem.sort(Site, list.items, {}, struct {
            fn more(_: void, x: Site, y: Site) bool {
                return x.bytes > y.bytes;
            }
        }.more);
        std.debug.print("\n== allocation sites of {s}\n", .{name});
        for (list.items[0..@min(n, list.items.len)]) |*site| {
            std.debug.print("{d} allocations, {d} bytes at\n", .{ site.allocs, site.bytes });
            std.debug.dumpStackTrace(&.{ .return_addresses = site.frames[0..site.n], .skipped = .none });
        }
        s.map.clearRetainingCapacity();
    }
};

/// The memory in use now and its peak, of the counters that share it (the
/// server's own: a request's arena frees nothing until it is reset)
pub const Live = struct {
    cur: std.atomic.Value(i64) = .init(0),
    peak: std.atomic.Value(i64) = .init(0),

    fn add(l: *Live, n: usize) void {
        const v = l.cur.fetchAdd(@intCast(n), .monotonic) + @as(i64, @intCast(n));
        _ = l.peak.fetchMax(v, .monotonic);
    }

    fn sub(l: *Live, n: usize) void {
        _ = l.cur.fetchSub(@intCast(n), .monotonic);
    }

    /// Starts a new peak from what is in use now
    pub fn resetPeak(l: *Live) void {
        l.peak.store(l.cur.load(.monotonic), .monotonic);
    }
};

pub const Counter = struct {
    child: Allocator,
    sites: ?*Sites = null,
    live: ?*Live = null,
    allocs: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),

    pub const Snapshot = struct { allocs: u64, bytes: u64 };

    pub fn init(child: Allocator) Counter {
        return .{ .child = child };
    }

    pub fn allocator(c: *Counter) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn snapshot(c: *const Counter) Snapshot {
        return .{ .allocs = c.allocs.load(.monotonic), .bytes = c.bytes.load(.monotonic) };
    }

    /// `len` bytes asked for, `new` of them in a new allocation
    fn ask(c: *Counter, len: usize, new: bool) void {
        if (c.sites) |s| s.add(len);
        if (new) _ = c.allocs.fetchAdd(1, .monotonic);
        _ = c.bytes.fetchAdd(len, .monotonic);
    }

    fn resized(c: *Counter, old: usize, new_len: usize) void {
        const l = c.live orelse return;
        if (new_len > old) l.add(new_len - old) else l.sub(old - new_len);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        const p = c.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        c.ask(len, true);
        c.resized(0, len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        if (!c.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) c.ask(new_len - memory.len, false);
        c.resized(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        const p = c.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        // in place, only the growth is new; moved, it is all new
        if (p == memory.ptr) {
            if (new_len > memory.len) c.ask(new_len - memory.len, false);
        } else c.ask(new_len, true);
        c.resized(memory.len, new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        c.child.rawFree(memory, alignment, ret_addr);
        c.resized(memory.len, 0);
    }
};

/// What the server's own allocator and the requests' have counted
pub const Counts = struct {
    server: Counter,
    request: Counter,
    live: Live = .{},
    sites: ?*Sites = null,

    pub fn total(c: *const Counts) Counter.Snapshot {
        const s = c.server.snapshot();
        const r = c.request.snapshot();
        return .{ .allocs = s.allocs + r.allocs, .bytes = s.bytes + r.bytes };
    }

    /// The peak of the server's memory in use since the last `Live.resetPeak`
    pub fn peak(c: *const Counts) u64 {
        return @intCast(c.live.peak.load(.monotonic));
    }
};
