//! Folded stacks and the ranked hot-function list of a profile run (the
//! sampler's output; see sampler.zig). Pure data handling, no threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Profile = struct {
    gpa: Allocator,
    /// "root;...;leaf" (names joined by `;`) to its sample count
    stacks: std.StringHashMapUnmanaged(u64) = .empty,
    total: u64 = 0,

    pub fn init(gpa: Allocator) Profile {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Profile) void {
        var it = self.stacks.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.stacks.deinit(self.gpa);
    }

    /// Adds one sample; `frames` run from the leaf to the root
    pub fn add(self: *Profile, frames: []const []const u8) Allocator.Error!void {
        if (frames.len == 0) return;
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(self.gpa);
        var i = frames.len;
        while (i > 0) {
            i -= 1;
            try key.appendSlice(self.gpa, frames[i]);
            if (i > 0) try key.append(self.gpa, ';');
        }
        self.total += 1;
        if (self.stacks.getPtr(key.items)) |n| {
            n.* += 1;
            return;
        }
        const owned = try key.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(owned);
        try self.stacks.put(self.gpa, owned, 1);
    }

    /// One line per distinct stack, "root;...;leaf count"
    pub fn writeFolded(self: *const Profile, w: *Writer) Writer.Error!void {
        var it = self.stacks.iterator();
        while (it.next()) |e| try w.print("{s} {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }

    const Row = struct { name: []const u8, count: u64 };

    fn lessRow(_: void, a: Row, b: Row) bool {
        if (a.count != b.count) return a.count > b.count;
        return std.mem.lessThan(u8, a.name, b.name);
    }

    /// The functions by samples with the function on top of the stack
    /// (exclusive) or anywhere in it (inclusive, once per sample)
    pub fn rank(self: *const Profile, a: Allocator, inclusive: bool) Allocator.Error![]Row {
        var counts: std.StringHashMapUnmanaged(u64) = .empty;
        defer counts.deinit(a);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(a);
        var it = self.stacks.iterator();
        while (it.next()) |e| {
            const n = e.value_ptr.*;
            if (!inclusive) {
                const leaf = if (std.mem.findScalarLast(u8, e.key_ptr.*, ';')) |p| e.key_ptr.*[p + 1 ..] else e.key_ptr.*;
                (try counts.getOrPutValue(a, leaf, 0)).value_ptr.* += n;
                continue;
            }
            seen.clearRetainingCapacity();
            var names = std.mem.splitScalar(u8, e.key_ptr.*, ';');
            while (names.next()) |name| {
                if ((try seen.getOrPut(a, name)).found_existing) continue;
                (try counts.getOrPutValue(a, name, 0)).value_ptr.* += n;
            }
        }
        const rows = try a.alloc(Row, counts.count());
        var i: usize = 0;
        var c = counts.iterator();
        while (c.next()) |e| : (i += 1) rows[i] = .{ .name = e.key_ptr.*, .count = e.value_ptr.* };
        std.mem.sort(Row, rows, {}, lessRow);
        return rows;
    }

    pub fn writeRanking(self: *const Profile, a: Allocator, w: *Writer, top: usize) !void {
        try w.print("samples: {d}\n", .{self.total});
        for ([_]bool{ false, true }) |inclusive| {
            const rows = try self.rank(a, inclusive);
            defer a.free(rows);
            try w.print("\n{s} (samples, percent, function)\n", .{if (inclusive) "inclusive" else "exclusive"});
            for (rows[0..@min(top, rows.len)]) |r| {
                const pct = if (self.total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(r.count)) / @as(f64, @floatFromInt(self.total));
                try w.print("{d:>8} {d:>6.2}%  {s}\n", .{ r.count, pct, r.name });
            }
        }
    }
};
