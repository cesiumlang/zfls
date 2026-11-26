//! The `processId` of an attach configuration: a number, or the string
//! that `${command:pickProcess}` gives

const std = @import("std");
const json = @import("../json.zig");
const Value = json.Value;

pub const Error = error{NotAProcessId};

/// The process `v` names, null when it is absent or empty; an error when it
/// is not a positive number of at most 32 bits
pub fn parse(v: ?Value) Error!?u32 {
    const p = v orelse return null;
    const n: i64 = switch (p) {
        .integer => |n| n,
        .string => |t| blk: {
            const digits = std.mem.trim(u8, t, " \t");
            if (digits.len == 0) return null;
            break :blk std.fmt.parseInt(i64, digits, 10) catch return error.NotAProcessId;
        },
        .null => return null,
        else => return error.NotAProcessId,
    };
    if (n <= 0 or n > std.math.maxInt(u32)) return error.NotAProcessId;
    return @intCast(n);
}

test "a processId: a number or its text; anything else is an error" {
    try std.testing.expectEqual(@as(?u32, 123), try parse(.{ .integer = 123 }));
    try std.testing.expectEqual(@as(?u32, 4567), try parse(.{ .string = " 4567 " }));
    try std.testing.expectEqual(@as(?u32, null), try parse(null));
    try std.testing.expectEqual(@as(?u32, null), try parse(.{ .string = "" }));
    try std.testing.expectEqual(@as(?u32, null), try parse(.null));
    try std.testing.expectError(error.NotAProcessId, parse(.{ .string = "x" }));
    try std.testing.expectError(error.NotAProcessId, parse(.{ .integer = -1 }));
    try std.testing.expectError(error.NotAProcessId, parse(.{ .integer = 0 }));
    try std.testing.expectError(error.NotAProcessId, parse(.{ .integer = 1 << 33 }));
    try std.testing.expectError(error.NotAProcessId, parse(.{ .bool = true }));
}
