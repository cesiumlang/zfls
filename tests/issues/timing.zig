//! Wall-clock check for what is waited for, not computed. Growth of work is
//! measured in counts (linear.zig), not seconds.

const std = @import("std");
const io = std.testing.io;

/// Fails if `seconds` pass after `before` (the awake clock's nanoseconds):
/// for what is waited for, not computed (a bound many times what it takes)
pub fn expectWithin(seconds: i96, before: i96) !void {
    try std.testing.expect(std.Io.Clock.awake.now(io).nanoseconds - before < seconds * std.time.ns_per_s);
}
