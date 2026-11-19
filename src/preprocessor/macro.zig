//! Macro substitution of the preprocessor: a macro's pattern and the text
//! that replaces each of its uses in a line

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const regex = @import("../regex.zig");

/// A macro ready to be substituted
pub const Compiled = struct {
    /// Matches a use of the macro; a function-like one's arguments are its
    /// groups, in order
    re: regex.Regex,
    /// The parameter names of a function-like macro, null for an object-like one
    params: ?[]const []const u8,

    pub fn deinit(self: *Compiled) void {
        self.re.deinit();
    }
};

/// Compile macro `name`; `args` is the text between the parentheses of a
/// function-like macro's definition, null for an object-like one.
pub fn compile(a: Allocator, name: []const u8, args: ?[]const u8) !Compiled {
    const arg_text = args orelse {
        const re = try regex.Regex.compile(a, try a.print("\\b{s}\\b", .{name}), .{});
        return .{ .re = re, .params = null };
    };
    var params: std.ArrayList([]const u8) = .empty;
    // `NAME()` has no parameters, not one with an empty name
    if (str.strip(arg_text).len > 0) {
        for (try str.split(a, arg_text, ",")) |p| try params.append(a, str.strip(p));
    }
    var pat: std.ArrayList(u8) = .empty;
    try pat.print(a, "\\b{s}\\s*\\(", .{name});
    if (params.items.len == 0) try pat.appendSlice(a, "\\s*");
    for (params.items, 0..) |_, i| {
        if (i > 0) try pat.append(a, ',');
        try pat.appendSlice(a, "(.*)");
    }
    try pat.appendSlice(a, "\\)");
    return .{ .re = try regex.Regex.compile(a, pat.items, .{}), .params = params.items };
}

/// Substitute the uses of macro `c` with `value` in `line`; `count` is the
/// number of uses
pub fn substitute(a: Allocator, c: *const Compiled, value: []const u8, line: []const u8) !regex.Regex.SubResult {
    var out: std.ArrayList(u8) = .empty;
    var it = c.re.iterator(line);
    var last: usize = 0;
    var count: usize = 0;
    while (it.next()) |m| {
        try out.appendSlice(a, line[last..m.start(0)]);
        try appendValue(a, &out, c, value, m);
        last = m.end(0);
        count += 1;
    }
    try out.appendSlice(a, line[last..]);
    return .{ .out = out.items, .count = count };
}

/// Append the value of macro `c` with the arguments of use `m` in place of
/// its parameters. The value is taken as it is, never as a regex template.
fn appendValue(a: Allocator, out: *std.ArrayList(u8), c: *const Compiled, v: []const u8, m: regex.Match) !void {
    const params = c.params orelse return out.appendSlice(a, v);
    var i: usize = 0;
    while (i < v.len) {
        if (!regex.isWordChar(v[i])) {
            try out.append(a, v[i]);
            i += 1;
            continue;
        }
        const start = i;
        while (i < v.len and regex.isWordChar(v[i])) i += 1;
        const word = v[start..i];
        try out.appendSlice(a, for (params, 0..) |p, k| {
            if (std.mem.eql(u8, p, word)) break m.group(@intCast(k + 1)) orelse "";
        } else word);
    }
}

const testing = std.testing;

fn expectSubstituted(name: []const u8, args: ?[]const u8, value: []const u8, line: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try compile(a, name, args);
    defer c.deinit();
    const res = try substitute(a, &c, value, line);
    try testing.expectEqualStrings(want, res.out);
}

test "a function-like macro without parameters expands to its value" {
    try expectSubstituted("NOARG", "", "42", "i = NOARG()", "i = 42");
    try expectSubstituted("NOARG", " ", "42", "i = NOARG( )", "i = 42");
    try expectSubstituted("CHECK", "", "if (ie /= 0) return", "CHECK()", "if (ie /= 0) return");
    // without parentheses it is not a use
    try expectSubstituted("NOARG", "", "42", "i = NOARG", "i = NOARG");
}

test "a macro's value is not read as a regex template" {
    try expectSubstituted("BS", "", "'a\\1b'", "x = BS()", "x = 'a\\1b'");
    try expectSubstituted("BS", null, "'a\\1b'", "x = BS", "x = 'a\\1b'");
    try expectSubstituted("ONE", "x", "x // '\\1'", "y = ONE(z)", "y = z // '\\1'");
}

test "a function-like macro's parameters are replaced as whole words" {
    try expectSubstituted("ONE", "x", "(x + 1)", "i = ONE(i)", "i = (i + 1)");
    try expectSubstituted("SQ", "x", "((x)*(x)) + xx + x1", "y = SQ(z)", "y = ((z)*(z)) + xx + x1");
    try expectSubstituted("ADD", "a, b", "a + b", "y = ADD(p, q)", "y = p +  q");
}
