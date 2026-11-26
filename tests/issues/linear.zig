//! Growth checks that do not depend on the machine: the server's
//! allocations and the bytes asked for (counting.zig) are compared between
//! two sizes of the same job, never seconds. A job that does quadratic work
//! asks for quadratically more; the one backstop in seconds is far above
//! any runner's pace, for work that allocates nothing.

const std = @import("std");
const counting = @import("counting.zig");
const io = std.testing.io;

/// The size step: 8 times the work is 8 times the counts if linear, 64 if quadratic
const step = 8;
/// The most a linear job's counts may grow (a little over `step`: a fixed cost
/// and rounding of buffers); quadratic is 64
const linear_limit = 12;
/// The seconds the big job may take (a fraction of a second on any machine now,
/// 20 to 30 seconds when quadratic)
const backstop_s = 15;

/// A job, run with the counts of the workspace it makes
pub const Job = fn (usize, *counting.Counts) anyerror!void;

fn fresh() counting.Counts {
    return .{ .server = .init(std.testing.allocator), .request = .init(std.testing.allocator) };
}

/// Fails unless `job(big)` (`big` is 8 times `small`) allocates and asks for
/// less than 12 times what `job(small)` does, and takes less than 15 seconds
pub fn expectLinear(comptime job: Job, small: usize, big: usize) !void {
    std.debug.assert(big == small * step);
    var s = fresh();
    try job(small, &s);
    var b = fresh();
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    try job(big, &b);
    const took = std.Io.Clock.awake.now(io).nanoseconds - before;
    const cs = s.total();
    const cb = b.total();
    if (cb.allocs > linear_limit * cs.allocs or cb.bytes > linear_limit * cs.bytes) {
        std.debug.print("{d} allocations and {d} bytes for {d}, {d} and {d} for {d}: more than {d} times\n", .{ cs.allocs, cs.bytes, small, cb.allocs, cb.bytes, big, linear_limit });
        return error.TestUnexpectedResult;
    }
    if (took > backstop_s * std.time.ns_per_s) {
        std.debug.print("{d} ms for {d}: more than {d} seconds\n", .{ @divTrunc(took, std.time.ns_per_ms), big, backstop_s });
        return error.TestUnexpectedResult;
    }
}
