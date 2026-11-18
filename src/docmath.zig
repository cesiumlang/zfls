//! Math in documentation comments (#272, `doc_math`): Doxygen's and FORD's
//! formula markers, `\f$ x \f$`, `\( x \)`, `\f[ x \f]`, `\[ x \]` and
//! `\f{env}{ x \f}`, rewritten in the Markdown sent to the client. LSP has
//! no capability by which a client says that its Markdown renders math,
//! so a setting chooses.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Mode = enum {
    /// the text as it is written
    keep,
    /// `$x$` and `$$x$$`, for clients that render KaTeX or MathJax
    dollar,
    /// the formula in backticks, without its markers
    plain,

    /// The mode a `doc_math` setting names; `keep` for any other value
    pub fn of(name: ?[]const u8) Mode {
        const n = name orelse return .keep;
        inline for (@typeInfo(Mode).@"enum".field_names) |f| if (std.ascii.eqlIgnoreCase(n, f)) return @field(Mode, f);
        return .keep;
    }
};

/// Markdown `md` with its formulas rewritten for `mode`. Code blocks
/// (between ``` fences) are left as they are, and so is a marker that is
/// not closed.
pub fn rewrite(a: Allocator, md: []const u8, mode: Mode) ![]const u8 {
    if (mode == .keep or std.mem.findScalar(u8, md, '\\') == null) return md;
    var out: std.ArrayList(u8) = .empty;
    var in_code = false;
    var lines = std.mem.splitScalar(u8, md, '\n');
    // the text between fences, rewritten as one (a formula may go on over
    // a line)
    var text_start: usize = 0;
    var pos: usize = 0;
    while (lines.next()) |line| {
        const line_start = pos;
        pos += line.len + 1;
        if (!std.mem.startsWith(u8, line, "```")) continue;
        if (!in_code) try rewriteText(a, &out, md[text_start..line_start], mode) else try out.appendSlice(a, md[text_start..line_start]);
        in_code = !in_code;
        try out.appendSlice(a, md[line_start..@min(pos, md.len)]);
        text_start = @min(pos, md.len);
    }
    if (text_start < md.len) {
        if (!in_code) try rewriteText(a, &out, md[text_start..], mode) else try out.appendSlice(a, md[text_start..]);
    }
    return out.items;
}

const Pair = struct { open: []const u8, close: []const u8, display: bool };

const pairs = [_]Pair{
    .{ .open = "\\f$", .close = "\\f$", .display = false },
    .{ .open = "\\(", .close = "\\)", .display = false },
    .{ .open = "\\f[", .close = "\\f]", .display = true },
    .{ .open = "\\[", .close = "\\]", .display = true },
};

fn rewriteText(a: Allocator, out: *std.ArrayList(u8), text: []const u8, mode: Mode) !void {
    var i: usize = 0;
    outer: while (i < text.len) {
        if (text[i] != '\\') {
            try out.append(a, text[i]);
            i += 1;
            continue;
        }
        const rest = text[i..];
        for (pairs) |p| if (std.mem.startsWith(u8, rest, p.open)) {
            const body_start = i + p.open.len;
            if (std.mem.find(u8, text[body_start..], p.close)) |n| {
                try emit(a, out, text[body_start .. body_start + n], null, p.display, mode);
                i = body_start + n + p.close.len;
                if (p.display) i = skipBlanks(text, i);
                continue :outer;
            }
        };
        // \f{env}{ x \f}
        if (std.mem.startsWith(u8, rest, "\\f{")) if (std.mem.findScalarPos(u8, text, i + 3, '}')) |env_end| {
            const env = text[i + 3 .. env_end];
            var body_start = env_end + 1;
            if (body_start < text.len and text[body_start] == '{') body_start += 1;
            if (env.len > 0 and std.mem.findScalar(u8, env, '\n') == null) if (std.mem.find(u8, text[body_start..], "\\f}")) |n| {
                try emit(a, out, text[body_start .. body_start + n], env, true, mode);
                i = skipBlanks(text, body_start + n + 3);
                continue :outer;
            };
        };
        try out.append(a, text[i]);
        i += 1;
    }
}

fn skipBlanks(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// A formula `body` (of environment `env`), inline or on lines of its own
fn emit(a: Allocator, out: *std.ArrayList(u8), body: []const u8, env: ?[]const u8, display: bool, mode: Mode) !void {
    // a formula over several comment lines is one
    const one = try a.dupe(u8, std.mem.trim(u8, body, " \t\n"));
    std.mem.replaceScalar(u8, one, '\n', ' ');
    if (display) {
        while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t')) out.items.len -= 1;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
    }
    switch (mode) {
        .keep => unreachable,
        .dollar => {
            try out.appendSlice(a, if (display) "$$" else "$");
            if (env) |e| try out.print(a, "\\begin{{{s}}}{s}\\end{{{s}}}", .{ e, one, e }) else try out.appendSlice(a, one);
            try out.appendSlice(a, if (display) "$$" else "$");
        },
        .plain => {
            // a backtick in the formula needs a longer fence
            const fence: []const u8 = if (std.mem.findScalar(u8, one, '`') != null) "`` " else "`";
            const close: []const u8 = if (fence.len > 1) " ``" else "`";
            try out.print(a, "{s}{s}{s}", .{ fence, one, close });
        },
    }
    if (display) try out.append(a, '\n');
}

fn expectRewrite(mode: Mode, in: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(want, try rewrite(arena.allocator(), in, mode));
}

test "doc_math rewrites each pair of formula markers" {
    try expectRewrite(.dollar, "E \\f$ E = m c^2 \\f$.", "E $E = m c^2$.");
    try expectRewrite(.plain, "E \\f$ E = m c^2 \\f$.", "E `E = m c^2`.");
    try expectRewrite(.dollar, "FORD: \\( v \\ge 0 \\)", "FORD: $v \\ge 0$");
    try expectRewrite(.plain, "FORD: \\( v \\ge 0 \\)", "FORD: `v \\ge 0`");
    try expectRewrite(.dollar, "or \\f[ E = \\int F \\, dx \\f] then", "or\n$$E = \\int F \\, dx$$\nthen");
    try expectRewrite(.plain, "or \\f[ x_1 \\f]", "or\n`x_1`\n");
    try expectRewrite(.dollar, "\\[ a \\]", "$$a$$\n");
    try expectRewrite(.dollar, "\\f{eqnarray*}{ a &=& b \\f}", "$$\\begin{eqnarray*}a &=& b\\end{eqnarray*}$$\n");
    try expectRewrite(.plain, "\\f{align}{ a = b \\f}", "`a = b`\n");
}

test "doc_math: a formula over two lines, unmatched markers, text without math, code blocks" {
    try expectRewrite(.dollar, "Kinetic \\f$ E =\n\\frac{1}{2} \\f$ x", "Kinetic $E = \\frac{1}{2}$ x");
    try expectRewrite(.dollar, "an open \\f$ x and no end", "an open \\f$ x and no end");
    try expectRewrite(.dollar, "cost in $, a \\ alone", "cost in $, a \\ alone");
    try expectRewrite(.dollar, "```fortran90\nx = '\\f$ y \\f$'\n```\n-----\n\\f$ z \\f$", "```fortran90\nx = '\\f$ y \\f$'\n```\n-----\n$z$");
    try expectRewrite(.keep, "\\f$ x \\f$", "\\f$ x \\f$");
    try expectRewrite(.plain, "\\f$ a`b \\f$", "`` a`b ``");
    try std.testing.expectEqual(Mode.dollar, Mode.of("Dollar"));
    try std.testing.expectEqual(Mode.keep, Mode.of("other"));
    try std.testing.expectEqual(Mode.keep, Mode.of(null));
}
