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
/// Outside character literals and `!` comments, `a ## b` pastes `a` and `b`
/// together (Intel fpp, flang, ISO cpp), `#param` is the argument in double
/// quotes and `/**/` is removed (gfortran's traditional cpp joins the words
/// around it).
fn appendValue(a: Allocator, out: *std.ArrayList(u8), c: *const Compiled, v: []const u8, m: regex.Match) !void {
    const params = c.params orelse &.{};
    const value_start = out.items.len;
    var quote: ?u8 = null;
    var comment = false;
    var i: usize = 0;
    while (i < v.len) {
        const ch = v[i];
        if (regex.isWordChar(ch)) {
            const start = i;
            while (i < v.len and regex.isWordChar(v[i])) i += 1;
            const word = v[start..i];
            try out.appendSlice(a, argument(params, m, word) orelse word);
            continue;
        }
        i += 1;
        if (comment) {
            try out.append(a, ch);
            continue;
        }
        if (quote) |q| {
            if (ch == q) quote = null;
            try out.append(a, ch);
            continue;
        }
        switch (ch) {
            '\'', '"' => quote = ch,
            '!' => comment = true,
            '/' => if (std.mem.startsWith(u8, v[i..], "**/")) {
                i += 3;
                continue;
            },
            '#' => {
                if (i < v.len and v[i] == '#') {
                    while (out.items.len > value_start and isBlank(out.items[out.items.len - 1])) out.items.len -= 1;
                    i += 1;
                    while (i < v.len and isBlank(v[i])) i += 1;
                    continue;
                }
                var j = i;
                while (j < v.len and isBlank(v[j])) j += 1;
                const name_start = j;
                while (j < v.len and regex.isWordChar(v[j])) j += 1;
                if (argument(params, m, v[name_start..j])) |arg| {
                    try appendQuoted(a, out, arg);
                    i = j;
                    continue;
                }
            },
            else => {},
        }
        try out.append(a, ch);
    }
}

/// The argument of use `m` for parameter `word`, without the white space
/// around it; null when `word` is no parameter
fn argument(params: []const []const u8, m: regex.Match, word: []const u8) ?[]const u8 {
    for (params, 0..) |p, k| {
        if (std.mem.eql(u8, p, word)) return str.strip(m.group(@intCast(k + 1)) orelse "");
    }
    return null;
}

fn isBlank(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

/// Append `text` as a Fortran character literal in double quotes
fn appendQuoted(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(a, '"');
    for (text) |ch| {
        if (ch == '"') try out.append(a, '"');
        try out.append(a, ch);
    }
    try out.append(a, '"');
}

/// `line` without the empty C comments (`/**/`) outside its character
/// literals and its `!` comment: gfortran preprocesses in cpp's traditional
/// mode, which joins the words around them (`pre/**/fix` is `prefix`)
pub fn removeEmptyComments(a: Allocator, line: []const u8) ![]const u8 {
    if (std.mem.find(u8, line, "/**/") == null) return line;
    var out: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];
        if (quote) |q| {
            if (ch == q) quote = null;
        } else if (ch == '!') {
            break;
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
        } else if (std.mem.startsWith(u8, line[i..], "/**/")) {
            i += 4;
            continue;
        }
        try out.append(a, ch);
        i += 1;
    }
    try out.appendSlice(a, line[i..]);
    return out.items;
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
    try expectSubstituted("ADD", "a, b", "a + b", "y = ADD(p, q)", "y = p + q");
}

test "token pasting and stringification in a macro's value (#226)" {
    try expectSubstituted("PASTE", "a,b", "a##b", "integer :: PASTE(my,var)", "integer :: myvar");
    try expectSubstituted("PASTE", "a,b", "a ## b", "x = PASTE(my, var)", "x = myvar");
    try expectSubstituted("WRAP", "P", "P , wrap_/**/P", "procedure :: WRAP(abc)", "procedure :: abc , wrap_abc");
    try expectSubstituted("STR", "x", "#x", "print *, STR(hello)", "print *, \"hello\"");
    try expectSubstituted("STR", "x", "# x", "print *, STR( a\"b )", "print *, \"a\"\"b\"");
    try expectSubstituted("CAT", null, "pre##fix /**/", "x = CAT", "x = prefix ");
    // not in character literals and comments, and `#` before no parameter stays
    try expectSubstituted("Q", "x", "'x##y', \"#x/**/\" ! a##b", "print *, Q(1)", "print *, '1##y', \"#1/**/\" ! a##b");
    try expectSubstituted("H", "x", "#y + x", "z = H(1)", "z = #y + 1");
}

test "empty C comments are removed outside character literals and comments (#226)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("integer :: prefix", try removeEmptyComments(a, "integer :: pre/**/fix"));
    try testing.expectEqualStrings("print *, \"a##b\", 'x/**/y'", try removeEmptyComments(a, "print *, \"a##b\", 'x/**/y'"));
    try testing.expectEqualStrings("x = ab ! c/**/d", try removeEmptyComments(a, "x = a/**/b ! c/**/d"));
}
