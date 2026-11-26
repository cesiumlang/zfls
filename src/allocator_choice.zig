const std = @import("std");
const sysinfo = @import("builtin");

/// Whether the server uses the checking allocator (`init.gpa`, the safe
/// build's `SafeAllocator`) instead of `std.heap.smp_allocator`: always in
/// debug builds, elsewhere when `ZFLS_SAFE_ALLOC` is `1`.
pub fn useChecking(optimize: std.lang.Optimize, env_value: ?[]const u8) bool {
    if (optimize == .debug) return true;
    const v = env_value orelse return false;
    return std.mem.eql(u8, v, "1");
}

/// The allocator for this process, chosen once at start
pub fn pick(init: std.process.Init) std.mem.Allocator {
    if (useChecking(sysinfo.optimize, init.environ_map.get("ZFLS_SAFE_ALLOC"))) return init.gpa;
    return std.heap.smp_allocator;
}

test "the checking allocator: debug builds, or ZFLS_SAFE_ALLOC=1" {
    try std.testing.expect(useChecking(.debug, null));
    try std.testing.expect(!useChecking(.safe, null));
    try std.testing.expect(!useChecking(.fast, "0"));
    try std.testing.expect(!useChecking(.safe, ""));
    try std.testing.expect(useChecking(.safe, "1"));
    try std.testing.expect(useChecking(.small, "1"));
}
