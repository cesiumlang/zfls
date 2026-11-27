//! zfls's own formatter (#986), the part on text: free-form lines indented
//! by their depths (server/indent_format.zig works them out from the
//! parser's scopes). It changes the blanks before and after a line's text
//! only, never the text, so every token stays as it was.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `lines` with each line's text at `width` blanks per level of its depth;
/// a line of null depth as it is (a preprocessor's line, or one that goes
/// on in a character literal); blank lines empty; blanks after the text
/// removed but in a line whose text is null-depth
pub fn indent(a: Allocator, lines: []const []const u8, depths: []const ?usize, width: usize) ![]const []const u8 {
    const out = try a.alloc([]const u8, lines.len);
    for (lines, depths, out) |line, depth, *o| {
        const d = depth orelse {
            o.* = line;
            continue;
        };
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) {
            o.* = "";
            continue;
        }
        const buf = try a.alloc(u8, d * width + text.len);
        @memset(buf[0 .. d * width], ' ');
        @memcpy(buf[d * width ..], text);
        o.* = buf;
    }
    return out;
}

/// `lines` with each preprocessor directive nested by its `#if`s: `width`
/// blanks per level after its `#`, which stays in column 1
/// (`--indent-directives`); `#else`, `#elif` and `#endif` at their `#if`'s
pub fn directives(a: Allocator, lines: []const []const u8, width: usize) ![]const []const u8 {
    const out = try a.dupe([]const u8, lines);
    var depth: usize = 0;
    for (out) |*l| {
        if (l.len == 0 or l.*[0] != '#') continue;
        const rest = std.mem.trimStart(u8, l.*[1..], " \t");
        const word = rest[0 .. std.mem.findAny(u8, rest, " \t(\r") orelse rest.len];
        const opens = std.mem.startsWith(u8, word, "if");
        const middle = std.mem.eql(u8, word, "else") or std.mem.eql(u8, word, "elif");
        if (std.mem.eql(u8, word, "endif") or middle) depth -|= 1;
        const buf = try a.alloc(u8, 1 + depth * width + rest.len);
        buf[0] = '#';
        @memset(buf[1 .. 1 + depth * width], ' ');
        @memcpy(buf[1 + depth * width ..], rest);
        l.* = buf;
        if (opens or middle) depth += 1;
    }
    return out;
}

/// Whether a free-form line's code ends inside a character literal that
/// the next line goes on with (`'abc&`), from the quote it starts in
/// (`quote`, 0: none); the quote it ends in
pub fn endQuote(line: []const u8, start_quote: u8) u8 {
    var quote = start_quote;
    var i: usize = 0;
    // a continued literal's line may start with `&`
    if (quote != 0) {
        const lead = std.mem.trimStart(u8, line, " \t");
        if (lead.len > 0 and lead[0] == '&') i = line.len - lead.len + 1;
    }
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == quote) {
                // a doubled quote stays in the literal
                if (i + 1 < line.len and line[i + 1] == quote) {
                    i += 1;
                    continue;
                }
                quote = 0;
            }
            continue;
        }
        if (c == '\'' or c == '"') quote = c else if (c == '!') return 0;
    }
    return quote;
}

/// The tokens of `lines` without the blanks between them: what a format
/// must keep, for the tests
pub fn tokens(a: Allocator, lines: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines) |l| for (l) |c| if (c != ' ' and c != '\t' and c != '\r') try out.append(a, c);
    return out.items;
}

const testing = std.testing;

test "lines indented by their depths, their text as it was (#986)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = [_][]const u8{ "module m", "integer :: k   ", "", "#ifdef X", "      contains" };
    const got = try indent(a, &lines, &.{ 0, 1, 1, null, 0 }, 3);
    try testing.expectEqualStrings("module m", got[0]);
    try testing.expectEqualStrings("   integer :: k", got[1]);
    try testing.expectEqualStrings("", got[2]);
    try testing.expectEqualStrings("#ifdef X", got[3]);
    try testing.expectEqualStrings("contains", got[4]);
    try testing.expectEqualStrings(try tokens(a, &lines), try tokens(a, got));
}

test "directives nested by their #ifs, the # in column 1 (#986)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = [_][]const u8{ "#ifdef A", "#if B", "#define C 1", "#else", "x = 1", "#endif", "#  endif", "#include \"f.h\"" };
    const got = try directives(a, &lines, 2);
    const want = [_][]const u8{ "#ifdef A", "#  if B", "#    define C 1", "#  else", "x = 1", "#  endif", "#endif", "#include \"f.h\"" };
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "a character literal that goes on to the next line (#986)" {
    try testing.expectEqual('\'', endQuote("  s = 'abc &", 0));
    try testing.expectEqual(0, endQuote("  & def'", '\''));
    try testing.expectEqual(0, endQuote("  s = 'it''s' ! 'x", 0));
    try testing.expectEqual('"', endQuote("x = \"a", 0));
}
