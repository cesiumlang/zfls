//! The macros the preprocessors of gfortran and ifx (fpp) define of the
//! line they expand on: `__LINE__` (its number), `__FILE__` (the file's
//! name, as `"pp.F90"`), `__DATE__` (`"Nov 20 2026"`) and `__TIME__`
//! (`"21:35:17"`, UTC here) (#507). A definition of the same name wins.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const names = [_][]const u8{ "__LINE__", "__FILE__", "__DATE__", "__TIME__" };

/// What the line being expanded is
pub const Site = struct {
    io: Io,
    /// the file's name, without its directory
    file: []const u8,
    /// 1-based
    line: usize,
};

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `line` with the macros of `names` that `defined` does not name replaced
/// by their values, outside character literals; null when it has none
pub fn expand(a: Allocator, line: []const u8, site: Site, defined: anytype) !?[]const u8 {
    if (std.mem.find(u8, line, "__") == null) return null;
    var out: std.ArrayList(u8) = .empty;
    var any = false;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (quote) |q| {
            if (c == q) quote = null;
        } else if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '_' and (i == 0 or !isWordChar(line[i - 1]))) {
            var end = i;
            while (end < line.len and isWordChar(line[end])) end += 1;
            const word = line[i..end];
            const which: ?usize = for (names, 0..) |n, k| {
                if (std.mem.eql(u8, word, n) and !defined.contains(n)) break k;
            } else null;
            if (which) |k| {
                try value(a, &out, k, site);
                any = true;
            } else try out.appendSlice(a, word);
            i = end;
            continue;
        }
        try out.append(a, c);
        i += 1;
    }
    return if (any) out.items else null;
}

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn value(a: Allocator, out: *std.ArrayList(u8), k: usize, site: Site) !void {
    switch (k) {
        0 => try out.print(a, "{d}", .{site.line}),
        1 => try out.print(a, "\"{s}\"", .{site.file}),
        else => {
            const secs: u64 = @intCast(@max(0, @divFloor(Io.Clock.real.now(site.io).nanoseconds, std.time.ns_per_s)));
            try out.appendSlice(a, if (k == 2) &date(secs) else &time(secs));
        },
    }
}

/// `"Mmm dd yyyy"`, C's `__DATE__` (the day padded with a blank)
fn date(secs: u64) [13]u8 {
    const day = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    var buf: [13]u8 = undefined;
    _ = std.mem.print(&buf, "\"{s} {d:>2} {d:0>4}\"", .{ months[md.month.numeric() - 1], md.day_index + 1, yd.year }) catch unreachable;
    return buf;
}

/// `"hh:mm:ss"`, C's `__TIME__`
fn time(secs: u64) [10]u8 {
    const ds = (std.time.epoch.EpochSeconds{ .secs = secs }).getDaySeconds();
    var buf: [10]u8 = undefined;
    _ = std.mem.print(&buf, "\"{d:0>2}:{d:0>2}:{d:0>2}\"", .{ ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch unreachable;
    return buf;
}

test "__LINE__, __FILE__, __DATE__ and __TIME__" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var none: std.StringHashMapUnmanaged(void) = .empty;
    const site: Site = .{ .io = std.testing.io, .file = "pp.F90", .line = 42 };
    try std.testing.expectEqualStrings("print *, 42, \"pp.F90\", '__LINE__', x__LINE__", (try expand(a, "print *, __LINE__, __FILE__, '__LINE__', x__LINE__", site, &none)).?);
    try std.testing.expect(try expand(a, "print *, __OTHER__", site, &none) == null);
    var user: std.StringHashMapUnmanaged(void) = .empty;
    try user.put(a, "__LINE__", {});
    try std.testing.expect(try expand(a, "print *, __LINE__", site, &user) == null);
    const dated = (try expand(a, "s = __DATE__ // __TIME__", site, &none)).?;
    try std.testing.expectEqual(@as(usize, "s = \"Nov 20 2026\" // \"21:35:17\"".len), dated.len);
    // 2026-11-05 09:07:03 UTC
    try std.testing.expectEqualStrings("\"Nov  5 2026\"", &date(1793869623));
    try std.testing.expectEqualStrings("\"09:07:03\"", &time(1793869623));
}
