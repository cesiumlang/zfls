//! Where the words of a file's code are: how many times a word occurs on
//! a range of lines, and whether the range has an include. Built once for
//! the file, so that asking for each of thousands of nested procedures
//! does not read their lines again (#803).

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const FortranFile = @import("parser.zig").FortranFile;

pub const WordIndex = struct {
    /// the 0-based lines of each word's (lowercase) occurrences, in order,
    /// one entry for each occurrence
    lines: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    /// how many lines before each line, and itself, include a file
    includes: []const u32,

    /// How many times `lower`, a word in lowercase, occurs on the 0-based
    /// lines `first`..`last`
    pub fn count(self: *const WordIndex, lower: []const u8, first: usize, last: usize) usize {
        const at = (self.lines.get(lower) orelse return 0).items;
        const lo = std.sort.lowerBound(u32, at, @as(u32, @intCast(first)), order);
        const hi = std.sort.upperBound(u32, at, @as(u32, @intCast(last)), order);
        return hi - lo;
    }

    /// Whether a line of `first`..`last` (0-based) includes a file
    pub fn hasInclude(self: *const WordIndex, first: usize, last: usize) bool {
        const before = if (first == 0) 0 else self.includes[first - 1];
        return self.includes[@min(last, self.includes.len - 1)] != before;
    }
};

fn order(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

/// The index of `file`'s code, with the macros expanded (a name in a macro's
/// value is used where the macro is). Comment lines have no words.
pub fn build(a: Allocator, file: *const FortranFile) Allocator.Error!WordIndex {
    const n = file.nLines();
    const includes = try a.alloc(u32, n);
    var index: WordIndex = .{ .includes = includes };
    var total: u32 = 0;
    for (0..n) |ln| {
        defer includes[ln] = total;
        const raw = file.getLine(ln, false) orelse continue;
        if (helpers.isComment(file.fixed, raw)) continue;
        const t = std.mem.trimStart(u8, raw, " \t");
        if (std.ascii.startsWithIgnoreCase(t, "include") or std.mem.startsWith(u8, t, "#") and std.mem.find(u8, t, "include") != null) {
            total += 1;
            continue;
        }
        var code = try helpers.stripStrings(a, file.getLine(ln, true) orelse raw, true);
        if (std.mem.findScalar(u8, code, '!')) |i| code = code[0..i];
        var it = helpers.words(code);
        while (it.next()) |w| {
            const gop = try index.lines.getOrPut(a, try std.ascii.allocLowerString(a, w.str));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, @intCast(ln));
        }
    }
    return index;
}
