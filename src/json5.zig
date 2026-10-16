//! JSON5 parser for configuration files (`.fortlsrc`, `.fortls.json5`,
//! `--pp_defs`). It reads a superset of JSON into a `std.json.Value`, the
//! type the language server protocol code uses too, and records the position
//! of a syntax error for `settings.json5ErrorMessage`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const ParseError = error{ SyntaxError, OutOfMemory };

pub const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    /// Position of the last error, for messages
    err_pos: usize = 0,

    pub fn parse(a: Allocator, src: []const u8) ParseError!Value {
        var p: Parser = .{ .a = a, .src = src };
        return p.parseDocument();
    }

    pub fn parseDocument(p: *Parser) ParseError!Value {
        // skip UTF-8 BOM
        if (std.mem.startsWith(u8, p.src, "\xEF\xBB\xBF")) p.pos = 3;
        const v = try p.parseValue();
        try p.skipWs();
        if (p.pos != p.src.len) return p.fail();
        return v;
    }

    fn fail(p: *Parser) ParseError {
        p.err_pos = p.pos;
        return error.SyntaxError;
    }

    fn skipWs(p: *Parser) ParseError!void {
        while (p.pos < p.src.len) {
            const c = p.src[p.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c) {
                p.pos += 1;
            } else if (c == 0xC2 and p.pos + 1 < p.src.len and p.src[p.pos + 1] == 0xA0) {
                p.pos += 2;
            } else if (c == '/' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == '/') {
                while (p.pos < p.src.len and p.src[p.pos] != '\n') p.pos += 1;
            } else if (c == '/' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == '*') {
                const end = std.mem.indexOfPos(u8, p.src, p.pos + 2, "*/") orelse return p.fail();
                p.pos = end + 2;
            } else break;
        }
    }

    fn parseValue(p: *Parser) ParseError!Value {
        try p.skipWs();
        if (p.pos >= p.src.len) return p.fail();
        const c = p.src[p.pos];
        switch (c) {
            '{' => return p.parseObject(),
            '[' => return p.parseArray(),
            '"', '\'' => return .{ .string = try p.parseString() },
            else => {},
        }
        if (p.matchWord("null")) return .null;
        if (p.matchWord("true")) return .{ .bool = true };
        if (p.matchWord("false")) return .{ .bool = false };
        return p.parseNumber();
    }

    fn matchWord(p: *Parser, w: []const u8) bool {
        if (!std.mem.startsWith(u8, p.src[p.pos..], w)) return false;
        const after = p.pos + w.len;
        if (after < p.src.len and isIdentChar(p.src[after])) return false;
        p.pos = after;
        return true;
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
    }

    fn parseNumber(p: *Parser) ParseError!Value {
        const start = p.pos;
        var neg = false;
        if (p.src[p.pos] == '+' or p.src[p.pos] == '-') {
            neg = p.src[p.pos] == '-';
            p.pos += 1;
        }
        if (p.matchWord("Infinity")) return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
        if (p.matchWord("NaN")) return .{ .float = std.math.nan(f64) };
        if (p.pos + 1 < p.src.len and p.src[p.pos] == '0' and (p.src[p.pos + 1] == 'x' or p.src[p.pos + 1] == 'X')) {
            p.pos += 2;
            const ds = p.pos;
            while (p.pos < p.src.len and std.ascii.isHex(p.src[p.pos])) p.pos += 1;
            const v = std.fmt.parseInt(i64, p.src[ds..p.pos], 16) catch return p.fail();
            return .{ .integer = if (neg) -v else v };
        }
        var is_float = false;
        const ds = p.pos;
        while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
        if (p.pos < p.src.len and p.src[p.pos] == '.') {
            is_float = true;
            p.pos += 1;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
        }
        if (p.pos < p.src.len and (p.src[p.pos] == 'e' or p.src[p.pos] == 'E')) {
            is_float = true;
            p.pos += 1;
            if (p.pos < p.src.len and (p.src[p.pos] == '+' or p.src[p.pos] == '-')) p.pos += 1;
            while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
        }
        if (p.pos == ds) return p.fail();
        const text = p.src[start..p.pos];
        if (!is_float) {
            if (std.fmt.parseInt(i64, text, 10)) |v| return .{ .integer = v } else |_| {}
        }
        const f = std.fmt.parseFloat(f64, if (text[0] == '+') text[1..] else text) catch return p.fail();
        return .{ .float = f };
    }

    fn parseString(p: *Parser) ParseError![]const u8 {
        const quote = p.src[p.pos];
        p.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.pos >= p.src.len) return p.fail();
            const c = p.src[p.pos];
            if (c == quote) {
                p.pos += 1;
                break;
            }
            if (c == '\\') {
                p.pos += 1;
                if (p.pos >= p.src.len) return p.fail();
                const e = p.src[p.pos];
                p.pos += 1;
                switch (e) {
                    'n' => try out.append(p.a, '\n'),
                    't' => try out.append(p.a, '\t'),
                    'r' => try out.append(p.a, '\r'),
                    'b' => try out.append(p.a, 0x08),
                    'f' => try out.append(p.a, 0x0c),
                    'v' => try out.append(p.a, 0x0b),
                    '0' => try out.append(p.a, 0),
                    '\n' => {},
                    '\r' => {
                        if (p.pos < p.src.len and p.src[p.pos] == '\n') p.pos += 1;
                    },
                    'x' => {
                        if (p.pos + 2 > p.src.len) return p.fail();
                        const v = std.fmt.parseInt(u8, p.src[p.pos .. p.pos + 2], 16) catch return p.fail();
                        p.pos += 2;
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(v, &buf) catch return p.fail();
                        try out.appendSlice(p.a, buf[0..n]);
                    },
                    'u' => {
                        var cp = try p.parseHex4();
                        if (cp >= 0xD800 and cp < 0xDC00 and std.mem.startsWith(u8, p.src[p.pos..], "\\u")) {
                            p.pos += 2;
                            const lo = try p.parseHex4();
                            if (lo >= 0xDC00 and lo < 0xE000) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            } else {
                                try appendCodepoint(p.a, &out, cp);
                                cp = lo;
                            }
                        }
                        try appendCodepoint(p.a, &out, cp);
                    },
                    else => try out.append(p.a, e),
                }
                continue;
            }
            try out.append(p.a, c);
            p.pos += 1;
        }
        return out.items;
    }

    fn appendCodepoint(a: Allocator, out: *std.ArrayList(u8), cp: u21) !void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
        try out.appendSlice(a, buf[0..n]);
    }

    fn parseHex4(p: *Parser) ParseError!u21 {
        if (p.pos + 4 > p.src.len) return p.fail();
        const v = std.fmt.parseInt(u21, p.src[p.pos .. p.pos + 4], 16) catch return p.fail();
        p.pos += 4;
        return v;
    }

    fn parseKey(p: *Parser) ParseError![]const u8 {
        try p.skipWs();
        if (p.pos >= p.src.len) return p.fail();
        const c = p.src[p.pos];
        if (c == '"' or c == '\'') return p.parseString();
        const start = p.pos;
        while (p.pos < p.src.len and isIdentChar(p.src[p.pos])) p.pos += 1;
        if (p.pos == start) return p.fail();
        return p.src[start..p.pos];
    }

    fn parseObject(p: *Parser) ParseError!Value {
        p.pos += 1;
        var obj: std.json.ObjectMap = .empty;
        while (true) {
            try p.skipWs();
            if (p.pos >= p.src.len) return p.fail();
            if (p.src[p.pos] == '}') {
                p.pos += 1;
                break;
            }
            const key = try p.parseKey();
            try p.skipWs();
            if (p.pos >= p.src.len or p.src[p.pos] != ':') return p.fail();
            p.pos += 1;
            const v = try p.parseValue();
            try obj.put(p.a, key, v);
            try p.skipWs();
            if (p.pos >= p.src.len) return p.fail();
            if (p.src[p.pos] == ',') {
                p.pos += 1;
            } else if (p.src[p.pos] != '}') return p.fail();
        }
        return .{ .object = obj };
    }

    fn parseArray(p: *Parser) ParseError!Value {
        p.pos += 1;
        var arr: std.json.Array = .init(p.a);
        while (true) {
            try p.skipWs();
            if (p.pos >= p.src.len) return p.fail();
            if (p.src[p.pos] == ']') {
                p.pos += 1;
                break;
            }
            try arr.append(try p.parseValue());
            try p.skipWs();
            if (p.pos >= p.src.len) return p.fail();
            if (p.src[p.pos] == ',') {
                p.pos += 1;
            } else if (p.src[p.pos] != ']') return p.fail();
        }
        return .{ .array = arr };
    }
};

pub fn parse(a: Allocator, src: []const u8) ParseError!Value {
    return Parser.parse(a, src);
}

test "json5 parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a, "{\"a\": [1, 2.5, \"x\\u00e9\"], 'b': true, c: null, /* c */ \"d\": {}, e: 0x10, \"a\": 3,}");
    const out = try std.json.Stringify.valueAlloc(a, v, .{});
    try std.testing.expectEqualStrings("{\"a\":3,\"b\":true,\"c\":null,\"d\":{},\"e\":16}", out);
    var p: Parser = .{ .a = a, .src = "{\n  \"x\": 1,\n  oops\n}" };
    try std.testing.expectError(error.SyntaxError, p.parseDocument());
    try std.testing.expectEqual(@as(usize, 19), p.err_pos);
}
