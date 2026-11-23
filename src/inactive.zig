//! The lines of a file that a preprocessor conditional leaves out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const FortranFile = @import("parser.zig").FortranFile;

pub const Inactive = struct {
    /// by 0-based line
    lines: []const bool,
    /// whether any line is left out
    any: bool,
};

pub fn of(a: Allocator, file: *const FortranFile) Allocator.Error!Inactive {
    const n = file.nLines();
    const lines = try a.alloc(bool, n);
    @memset(lines, false);
    var any = false;
    for (file.pp_skips) |sk| {
        var l = sk.start;
        while (l + 1 < sk.end and l < n) : (l += 1) {
            lines[l] = true;
            any = true;
        }
    }
    return .{ .lines = lines, .any = any };
}
