//! Wall-clock checks that hold on a slow or noisy runner: time is compared
//! between two sizes of the same job, never with a fixed number of seconds,
//! and a run that looks too slow is repeated (a noisy moment is not a trend).

const std = @import("std");
const io = std.testing.io;

/// Runs of each size before a ratio is called too high
const attempts = 3;
/// The size step: 8 times the work is 8 times the time if linear, 64 if quadratic
const step = 8;
/// The limit for a job that is linear (or close to it), between 8 and 64
const linear_limit = 24;
/// Times under this are noise, not a measure
const floor_ns = 20 * std.time.ns_per_ms;

/// Nanoseconds to run `job(n)`
fn timeOf(comptime job: fn (usize) anyerror!void, n: usize) !u64 {
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    try job(n);
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds - before);
}

/// Fails unless `job(big)` takes less than `limit` times as long as
/// `job(small)`; `big` is 8 times `small`. Each size is the best of up to 3
/// runs.
pub fn expectGrowth(comptime job: fn (usize) anyerror!void, small: usize, big: usize, limit: u64) !void {
    std.debug.assert(big == small * step);
    var best_small: u64 = std.math.maxInt(u64);
    var best_big: u64 = std.math.maxInt(u64);
    for (0..attempts) |_| {
        best_small = @min(best_small, try timeOf(job, small));
        best_big = @min(best_big, try timeOf(job, big));
        if (best_big < limit * @max(best_small, floor_ns)) return;
    }
    std.debug.print("{d} ms for {d}, {d} ms for {d}: more than {d} times\n", .{ best_small / std.time.ns_per_ms, small, best_big / std.time.ns_per_ms, big, limit });
    return error.TestUnexpectedResult;
}

/// `expectGrowth` for a job whose time is in step with its size: 8 times as
/// long for 8 times the size (24 is the limit; 64 is quadratic)
pub fn expectLinear(comptime job: fn (usize) anyerror!void, small: usize, big: usize) !void {
    try expectGrowth(job, small, big, linear_limit);
}

/// Fails if `seconds` pass after `before` (the awake clock's nanoseconds):
/// for what is waited for, not computed (a bound many times what it takes)
pub fn expectWithin(seconds: i96, before: i96) !void {
    try std.testing.expect(std.Io.Clock.awake.now(io).nanoseconds - before < seconds * std.time.ns_per_s);
}
