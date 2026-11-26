//! TOML for configuration files (`.zflsrc`), read into a JSON value: tables
//! (`[a.b]`), dotted keys, strings (basic, literal, multi-line), integers,
//! floats, booleans, arrays and inline tables. Dates and times, and arrays
//! of tables (`[[x]]`), are errors: no option takes them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const json5 = @import("json5.zig");

pub const ParseError = error{ SyntaxError, OutOfMemory };

pub const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    /// Where and what, after a `SyntaxError`
    err_pos: usize = 0,
    err_msg: []const u8 = "",
    /// Arrays and inline tables open around the value being read
    depth: usize = 0,

    fn fail(p: *Parser, msg: []const u8) ParseError {
        p.err_pos = p.pos;
        p.err_msg = msg;
        return error.SyntaxError;
    }

    /// 1-based line and column of `err_pos`
    pub fn errLocation(p: *const Parser) struct { line: usize, col: usize } {
        var line: usize = 1;
        var col: usize = 1;
        for (p.src[0..@min(p.err_pos, p.src.len)]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        return .{ .line = line, .col = col };
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn blanks(p: *Parser) void {
        while (p.peek()) |c| : (p.pos += 1) if (c != ' ' and c != '\t') break;
    }

    /// Blanks, a comment and the line end, if any
    fn endOfLine(p: *Parser) ParseError!void {
        p.blanks();
        if (p.peek() == '#') while (p.peek()) |c| : (p.pos += 1) if (c == '\n') break;
        if (p.peek() == '\r') p.pos += 1;
        if (p.peek()) |c| {
            if (c != '\n') return p.fail("expected the end of the line");
            p.pos += 1;
        }
    }

    /// Blanks, comments and line ends, inside an array
    fn space(p: *Parser) void {
        while (p.peek()) |c| {
            if (c == '#') {
                while (p.peek()) |d| : (p.pos += 1) if (d == '\n') break;
            } else if (c == ' ' or c == '\t' or c == '\r' or c == '\n') p.pos += 1 else break;
        }
    }

    pub fn parseDocument(p: *Parser) ParseError!json.Value {
        if (std.mem.startsWith(u8, p.src, "\xEF\xBB\xBF")) p.pos = 3;
        var root: json.ObjectMap = .empty;
        var table: *json.ObjectMap = &root;
        while (true) {
            p.space();
            const c = p.peek() orelse break;
            if (c == '[') {
                if (std.mem.startsWith(u8, p.src[p.pos..], "[[")) return p.fail("arrays of tables are not used in a configuration file");
                p.pos += 1;
                var path: std.ArrayList([]const u8) = .empty;
                try p.keyPath(&path);
                if (p.peek() != ']') return p.fail("expected ]");
                p.pos += 1;
                table = try p.descend(&root, path.items);
            } else {
                var path: std.ArrayList([]const u8) = .empty;
                try p.keyPath(&path);
                if (p.peek() != '=') return p.fail("expected =");
                p.pos += 1;
                p.blanks();
                const v = try p.value();
                const holder = try p.descend(table, path.items[0 .. path.items.len - 1]);
                const entry = try holder.getOrPut(p.a, path.items[path.items.len - 1]);
                if (entry.found_existing) return p.fail("the key is set twice");
                entry.value_ptr.* = v;
            }
            try p.endOfLine();
        }
        return .{ .object = root };
    }

    /// The table at `path` under `from`, made when missing
    fn descend(p: *Parser, from: *json.ObjectMap, path: []const []const u8) ParseError!*json.ObjectMap {
        var t = from;
        for (path) |k| {
            const e = try t.getOrPut(p.a, k);
            if (!e.found_existing) e.value_ptr.* = .{ .object = .empty };
            if (e.value_ptr.* != .object) return p.fail("the key is not a table");
            t = &e.value_ptr.object;
        }
        return t;
    }

    fn keyPath(p: *Parser, out: *std.ArrayList([]const u8)) ParseError!void {
        while (true) {
            p.blanks();
            try out.append(p.a, try p.key());
            p.blanks();
            if (p.peek() != '.') return;
            p.pos += 1;
        }
    }

    fn key(p: *Parser) ParseError![]const u8 {
        const c = p.peek() orelse return p.fail("expected a key");
        if (c == '"' or c == '\'') return p.string();
        const start = p.pos;
        while (p.peek()) |d| : (p.pos += 1) {
            if (!std.ascii.isAlphanumeric(d) and d != '_' and d != '-') break;
        }
        if (p.pos == start) return p.fail("expected a key");
        return p.src[start..p.pos];
    }

    /// One level deeper, at most `json5.max_depth`, as a configuration file
    /// in JSON is (#895): deeper ones would overflow the stack
    fn enter(p: *Parser) ParseError!void {
        if (p.depth >= json5.max_depth) return p.fail("nested too deeply");
        p.depth += 1;
    }

    fn value(p: *Parser) ParseError!json.Value {
        const c = p.peek() orelse return p.fail("expected a value");
        switch (c) {
            '"', '\'' => return .{ .string = try p.string() },
            '[' => return p.array(),
            '{' => return p.inlineTable(),
            else => {},
        }
        const start = p.pos;
        while (p.peek()) |d| : (p.pos += 1) switch (d) {
            ',', ']', '}', '#', ' ', '\t', '\r', '\n' => break,
            else => {},
        };
        const word = p.src[start..p.pos];
        if (std.mem.eql(u8, word, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, word, "false")) return .{ .bool = false };
        if (word.len == 0) return p.fail("expected a value");
        const digits = try p.a.alloc(u8, word.len);
        var n: usize = 0;
        for (word) |d| if (d != '_') {
            digits[n] = d;
            n += 1;
        };
        if (std.fmt.parseInt(i64, digits[0..n], 0)) |i| return .{ .integer = i } else |_| {}
        if (std.fmt.parseFloat(f64, digits[0..n])) |f| return .{ .float = f } else |_| {}
        p.pos = start;
        return p.fail("expected a string, number, boolean, array or table");
    }

    fn array(p: *Parser) ParseError!json.Value {
        try p.enter();
        defer p.depth -= 1;
        p.pos += 1;
        var items: json.Array = .init(p.a);
        while (true) {
            p.space();
            if (p.peek() == ']') {
                p.pos += 1;
                return .{ .array = items };
            }
            try items.append(try p.value());
            p.space();
            switch (p.peek() orelse return p.fail("expected ]")) {
                ',' => p.pos += 1,
                ']' => {},
                else => return p.fail("expected , or ]"),
            }
        }
    }

    fn inlineTable(p: *Parser) ParseError!json.Value {
        try p.enter();
        defer p.depth -= 1;
        p.pos += 1;
        var t: json.ObjectMap = .empty;
        while (true) {
            p.blanks();
            if (p.peek() == '}') {
                p.pos += 1;
                return .{ .object = t };
            }
            var path: std.ArrayList([]const u8) = .empty;
            try p.keyPath(&path);
            if (p.peek() != '=') return p.fail("expected =");
            p.pos += 1;
            p.blanks();
            const v = try p.value();
            const holder = try p.descend(&t, path.items[0 .. path.items.len - 1]);
            const e = try holder.getOrPut(p.a, path.items[path.items.len - 1]);
            if (e.found_existing) return p.fail("the key is set twice");
            e.value_ptr.* = v;
            p.blanks();
            switch (p.peek() orelse return p.fail("expected }")) {
                ',' => p.pos += 1,
                '}' => {},
                else => return p.fail("expected , or }"),
            }
        }
    }

    /// A basic or literal string, single or multi-line, at its quote
    fn string(p: *Parser) ParseError![]const u8 {
        const q = p.src[p.pos];
        const multi = std.mem.startsWith(u8, p.src[p.pos..], if (q == '"') "\"\"\"" else "'''");
        p.pos += if (multi) 3 else 1;
        // a newline right after the opening quotes is dropped
        if (multi) {
            if (p.peek() == '\r') p.pos += 1;
            if (p.peek() == '\n') p.pos += 1;
        }
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail("the string is not closed");
            if (c == q) {
                if (!multi) {
                    p.pos += 1;
                    return out.items;
                }
                if (std.mem.startsWith(u8, p.src[p.pos..], if (q == '"') "\"\"\"" else "'''")) {
                    p.pos += 3;
                    return out.items;
                }
            }
            if (c == '\n' and !multi) return p.fail("the string is not closed");
            if (c == '\\' and q == '"') {
                p.pos += 1;
                try p.escape(&out, multi);
                continue;
            }
            try out.append(p.a, c);
            p.pos += 1;
        }
    }

    fn escape(p: *Parser, out: *std.ArrayList(u8), multi: bool) ParseError!void {
        const c = p.peek() orelse return p.fail("the string is not closed");
        p.pos += 1;
        switch (c) {
            'n' => try out.append(p.a, '\n'),
            't' => try out.append(p.a, '\t'),
            'r' => try out.append(p.a, '\r'),
            'b' => try out.append(p.a, 8),
            'f' => try out.append(p.a, 12),
            'e' => try out.append(p.a, 27),
            '"', '\\' => try out.append(p.a, c),
            'u', 'U' => {
                const n: usize = if (c == 'u') 4 else 8;
                if (p.pos + n > p.src.len) return p.fail("expected hexadecimal digits");
                const cp = std.fmt.parseInt(u21, p.src[p.pos..][0..n], 16) catch return p.fail("expected hexadecimal digits");
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return p.fail("not a Unicode scalar value");
                try out.appendSlice(p.a, buf[0..len]);
                p.pos += n;
            },
            // a line ending backslash of a multi-line string drops the blanks up to the next text
            ' ', '\t', '\r', '\n' => {
                if (!multi) return p.fail("unknown escape");
                p.pos -= 1;
                while (p.peek()) |d| : (p.pos += 1) if (std.mem.findScalar(u8, " \t\r\n", d) == null) break;
            },
            else => return p.fail("unknown escape"),
        }
    }
};

/// The table `text` as a JSON object
pub fn parse(a: Allocator, text: []const u8) ParseError!json.Value {
    var p: Parser = .{ .a = a, .src = text };
    return p.parseDocument();
}

test "a configuration file's TOML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a,
        \\# a comment
        \\nthreads = 2  # trailing
        \\nthreads_off = true
        \\source_dirs = [
        \\  "src",   # first
        \\  'app\x',
        \\]
        \\compiler_path = "C:\\tools\\gfortran \u00e9"
        \\
        \\[pp_defs]
        \\A = 1
        \\"B.C" = "x"
        \\
        \\[diagnostic_severity]
        \\masks-parent = "off"
        \\inline = { a = 1, b.c = [1.5, false] }
        \\text = """
        \\two
        \\lines"""
    );
    try std.testing.expectEqual(@as(i64, 2), json.int(json.get(v, "nthreads")).?);
    try std.testing.expect(json.get(v, "nthreads_off").?.bool);
    const dirs = json.items(json.get(v, "source_dirs"));
    try std.testing.expectEqual(@as(usize, 2), dirs.len);
    try std.testing.expectEqualStrings("app\\x", dirs[1].string);
    try std.testing.expectEqualStrings("C:\\tools\\gfortran \u{e9}", json.str(json.get(v, "compiler_path")).?);
    try std.testing.expectEqualStrings("x", json.str(json.path(v, &.{ "pp_defs", "B.C" })).?);
    try std.testing.expectEqual(@as(i64, 1), json.int(json.path(v, &.{ "pp_defs", "A" })).?);
    try std.testing.expectEqualStrings("off", json.str(json.path(v, &.{ "diagnostic_severity", "masks-parent" })).?);
    try std.testing.expectEqualStrings("two\nlines", json.str(json.path(v, &.{ "diagnostic_severity", "text" })).?);
    try std.testing.expect(!json.path(v, &.{ "diagnostic_severity", "inline", "b", "c" }).?.array.items[1].bool);
}

test "TOML errors say where" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_]struct { []const u8, usize, usize }{
        .{ "a = 1\nb 2\n", 2, 3 },
        .{ "a = 1\na = 2\n", 2, 6 },
        .{ "a = [1, 2\n", 2, 1 },
        .{ "a = \"x\n", 1, 7 },
        .{ "[[t]]\n", 1, 1 },
        .{ "a = 1979-05-27\n", 1, 5 },
        .{ "a = 1 b = 2\n", 1, 7 },
    };
    for (bad) |b| {
        var p: Parser = .{ .a = a, .src = b[0] };
        try std.testing.expectError(error.SyntaxError, p.parseDocument());
        const at = p.errLocation();
        try std.testing.expectEqual(b[1], at.line);
        try std.testing.expectEqual(b[2], at.col);
    }
}

test "arrays nested too deeply are an error, not a stack overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = json5.max_depth + 1;
    const deep = try a.alloc(u8, 4 + 2 * n);
    @memcpy(deep[0..4], "x = ");
    @memset(deep[4 .. 4 + n], '[');
    @memset(deep[4 + n ..], ']');
    try std.testing.expectError(error.SyntaxError, parse(a, deep));
    const ok = try a.alloc(u8, 4 + 2 * (n - 1));
    @memcpy(ok[0..4], "x = ");
    @memset(ok[4 .. 4 + n - 1], '[');
    @memset(ok[4 + n - 1 ..], ']');
    _ = try parse(a, ok);
}
