//! ifx's `!DEC$ FIXEDFORMLINESIZE:n` (n 72, 80 or 132; also `!DIR$`, and
//! `C` or `*` in column 1): the line length of the fixed-form lines after
//! it, in place of `fixed_line_length` (#511).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A directive: its line (0-based) and length
pub const Directive = struct { line: usize, columns: usize };

/// The line lengths of a file: `default` (`fixed_line_length`, null: no
/// limit) up to its first directive, then each directive's
pub const Limits = struct {
    default: ?usize,
    directives: []const Directive = &.{},

    /// The line length of line `i` (0-based)
    pub fn at(self: Limits, i: usize) ?usize {
        var out = self.default;
        for (self.directives) |d| {
            if (d.line >= i) break;
            out = d.columns;
        }
        return out;
    }
};

/// The length line `line` sets, if it is the directive
pub fn directive(line: []const u8) ?usize {
    var rest = line;
    if (rest.len > 0 and (rest[0] == 'c' or rest[0] == 'C' or rest[0] == '*')) {
        rest = rest[1..];
    } else {
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == 0 or rest[0] != '!') return null;
        rest = rest[1..];
    }
    if (!std.ascii.startsWithIgnoreCase(rest, "dec$") and !std.ascii.startsWithIgnoreCase(rest, "dir$")) return null;
    rest = std.mem.trimStart(u8, rest[4..], " \t");
    const key = "fixedformlinesize";
    if (!std.ascii.startsWithIgnoreCase(rest, key)) return null;
    rest = std.mem.trimStart(u8, rest[key.len..], " \t");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t");
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    const after = std.mem.trimStart(u8, rest[end..], " \t\r");
    if (after.len > 0 and after[0] != '!') return null;
    const n = std.fmt.parseInt(usize, rest[0..end], 10) catch return null;
    return switch (n) {
        72, 80, 132 => n,
        else => null,
    };
}

/// The directives of `lines`, owned by `gpa`
pub fn directives(gpa: Allocator, lines: []const []const u8) ![]Directive {
    var out: std.ArrayList(Directive) = .empty;
    errdefer out.deinit(gpa);
    for (lines, 0..) |l, i| if (directive(l)) |n| try out.append(gpa, .{ .line = i, .columns = n });
    return out.toOwnedSlice(gpa);
}

test "FIXEDFORMLINESIZE" {
    try std.testing.expectEqual(@as(?usize, 132), directive("CDEC$ FIXEDFORMLINESIZE:132"));
    try std.testing.expectEqual(@as(?usize, 80), directive("!dir$ fixedformlinesize : 80 ! wider"));
    try std.testing.expectEqual(@as(?usize, 72), directive("*DEC$ FIXEDFORMLINESIZE:72"));
    try std.testing.expect(directive("CDEC$ FIXEDFORMLINESIZE:100") == null);
    try std.testing.expect(directive("CDEC$ FIXEDFORMLINESIZE") == null);
    try std.testing.expect(directive("      X = 1") == null);
    const gpa = std.testing.allocator;
    const ds = try directives(gpa, &.{ "      X = 1", "CDEC$ FIXEDFORMLINESIZE:132", "      Y = 2", "!DEC$ FIXEDFORMLINESIZE:72", "      Z = 3" });
    defer gpa.free(ds);
    const limits: Limits = .{ .default = null, .directives = ds };
    try std.testing.expectEqual(@as(?usize, null), limits.at(0));
    try std.testing.expectEqual(@as(?usize, null), limits.at(1));
    try std.testing.expectEqual(@as(?usize, 132), limits.at(2));
    try std.testing.expectEqual(@as(?usize, 72), limits.at(4));
}
