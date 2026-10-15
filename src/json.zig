//! Minimal JSON value model with a JSON5-capable parser and a compact,
//! ASCII-only writer (matching Python's `json.dumps(separators=(",", ":"))`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: std.ArrayList(Value),
    object: Object,

    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .object => |o| o.get(key),
            else => null,
        };
    }

    /// Get a nested value through a path of object keys
    pub fn path(self: Value, keys: []const []const u8) ?Value {
        var v = self;
        for (keys) |k| v = v.get(k) orelse return null;
        return v;
    }

    pub fn asStr(self: Value) ?[]const u8 {
        return if (self == .string) self.string else null;
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |i| i,
            .float => |f| if (@floor(f) == f and @abs(f) < 9e18) @intFromFloat(f) else null,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return if (self == .bool) self.bool else null;
    }

    pub fn items(self: Value) []Value {
        return if (self == .array) self.array.items else &.{};
    }

    pub fn isNull(self: Value) bool {
        return self == .null;
    }
};

pub const null_value: Value = .null;

pub const Entry = struct { key: []const u8, value: Value };

pub const Object = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn get(self: Object, key: []const u8) ?Value {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    pub fn put(self: *Object, a: Allocator, key: []const u8, value: Value) !void {
        for (self.entries.items) |*e| if (std.mem.eql(u8, e.key, key)) {
            e.value = value;
            return;
        };
        try self.entries.append(a, .{ .key = key, .value = value });
    }

    pub fn contains(self: Object, key: []const u8) bool {
        return self.get(key) != null;
    }
};

// --------------------------------------------------------------------------
// Construction helpers

pub fn string(s: []const u8) Value {
    return .{ .string = s };
}

pub fn integer(i: anytype) Value {
    return .{ .int = @intCast(i) };
}

pub fn newObject() Value {
    return .{ .object = .{} };
}

pub fn newArray() Value {
    return .{ .array = .empty };
}

pub fn append(a: Allocator, arr: *Value, v: Value) !void {
    try arr.array.append(a, v);
}

pub fn put(a: Allocator, obj: *Value, key: []const u8, v: Value) !void {
    try obj.object.put(a, key, v);
}

/// Convert a Zig value into a JSON `Value`. Structs become objects with
/// their fields in declaration order; `null` optionals become JSON null,
/// except those of fields that default to `null`, which are left out. A
/// struct with a `toJson(self, a)` method converts itself.
pub fn from(a: Allocator, x: anytype) Allocator.Error!Value {
    const T = @TypeOf(x);
    if (T == Value) return x;
    switch (@typeInfo(T)) {
        .null => return .null,
        .bool => return .{ .bool = x },
        .int, .comptime_int => return .{ .int = @intCast(x) },
        .float, .comptime_float => return .{ .float = x },
        .optional => return if (x) |v| from(a, v) else .null,
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return .{ .string = x };
            if (p.size == .one) {
                const C = @typeInfo(p.child);
                if (C == .array and C.array.child == u8) return .{ .string = x };
                return from(a, x.*);
            }
            if (p.size == .slice) {
                var arr: std.ArrayList(Value) = .empty;
                for (x) |item| try arr.append(a, try from(a, item));
                return .{ .array = arr };
            }
            @compileError("unsupported pointer type " ++ @typeName(T));
        },
        .array => {
            var arr: std.ArrayList(Value) = .empty;
            for (x) |item| try arr.append(a, try from(a, item));
            return .{ .array = arr };
        },
        .@"struct" => |s| {
            if (@hasDecl(T, "toJson")) return x.toJson(a);
            var obj: Object = .{};
            inline for (s.field_names, s.field_types, s.field_attrs) |fname, ftype, fattrs| {
                const val = @field(x, fname);
                const omit = comptime @typeInfo(ftype) == .optional and !fattrs.@"comptime" and fattrs.defaultValue(ftype) != null;
                if (!(omit and val == null)) {
                    try obj.entries.append(a, .{ .key = fname, .value = try from(a, val) });
                }
            }
            return .{ .object = obj };
        },
        else => @compileError("unsupported type " ++ @typeName(T)),
    }
}

pub const DecodeError = error{InvalidParams} || Allocator.Error;

/// Decode a JSON `Value` into a Zig value of type `T`: the inverse of `from`
/// for the types used by the protocol. Struct fields that are absent take
/// their default (an absent field without one is an error), unknown
/// properties are ignored, and strings and arrays point into / are allocated
/// from `a`.
pub fn to(comptime T: type, a: Allocator, v: Value) DecodeError!T {
    if (T == Value) return v;
    switch (@typeInfo(T)) {
        .bool => return v.asBool() orelse error.InvalidParams,
        .int => return std.math.cast(T, v.asInt() orelse return error.InvalidParams) orelse error.InvalidParams,
        .float => return switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => error.InvalidParams,
        },
        .optional => |o| return if (v == .null) null else try to(o.child, a, v),
        .pointer => |p| {
            if (p.size != .slice) @compileError("unsupported pointer type " ++ @typeName(T));
            if (p.child == u8) return v.asStr() orelse error.InvalidParams;
            if (v != .array) return error.InvalidParams;
            const out = try a.alloc(p.child, v.array.items.len);
            for (v.array.items, out) |item, *slot| slot.* = try to(p.child, a, item);
            return out;
        },
        .@"struct" => |s| {
            if (v != .object and v != .null) return error.InvalidParams;
            var r: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |fname, ftype, fattrs| {
                if (v.get(fname)) |fv| {
                    @field(r, fname) = try to(ftype, a, fv);
                } else if (fattrs.defaultValue(ftype)) |d| {
                    @field(r, fname) = d;
                } else {
                    return error.InvalidParams;
                }
            }
            return r;
        },
        else => @compileError("unsupported type " ++ @typeName(T)),
    }
}

// --------------------------------------------------------------------------
// Writer

pub fn writeString(out: *std.ArrayList(u8), a: Allocator, s: []const u8) !void {
    try out.append(a, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            0x08 => try out.appendSlice(a, "\\b"),
            0x0c => try out.appendSlice(a, "\\f"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    if (c == 0x7f) {
                        try out.append(a, c);
                    } else {
                        try out.print(a, "\\u{x:0>4}", .{c});
                    }
                } else if (c < 0x80) {
                    try out.append(a, c);
                } else {
                    // decode UTF-8; invalid bytes become U+FFFD
                    const len = std.unicode.utf8ByteSequenceLength(c) catch 0;
                    var cp: u21 = 0xFFFD;
                    var consumed: usize = 1;
                    if (len > 0 and i + len <= s.len) {
                        if (std.unicode.utf8Decode(s[i .. i + len])) |v| {
                            cp = v;
                            consumed = len;
                        } else |_| {}
                    }
                    if (cp >= 0x10000) {
                        const v = cp - 0x10000;
                        try out.print(a, "\\u{x:0>4}\\u{x:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
                    } else {
                        try out.print(a, "\\u{x:0>4}", .{cp});
                    }
                    i += consumed;
                    continue;
                }
            },
        }
        i += 1;
    }
    try out.append(a, '"');
}

fn writeFloat(out: *std.ArrayList(u8), a: Allocator, f: f64) !void {
    if (std.math.isNan(f)) return out.appendSlice(a, "NaN");
    if (std.math.isInf(f)) return out.appendSlice(a, if (f > 0) "Infinity" else "-Infinity");
    if (@floor(f) == f and @abs(f) < 1e16) {
        try out.print(a, "{d}.0", .{f});
    } else {
        try out.print(a, "{d}", .{f});
    }
}

pub fn write(out: *std.ArrayList(u8), a: Allocator, v: Value) Allocator.Error!void {
    switch (v) {
        .null => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .int => |i| try out.print(a, "{d}", .{i}),
        .float => |f| try writeFloat(out, a, f),
        .string => |s| try writeString(out, a, s),
        .array => |arr| {
            try out.append(a, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.append(a, ',');
                try write(out, a, item);
            }
            try out.append(a, ']');
        },
        .object => |o| {
            try out.append(a, '{');
            for (o.entries.items, 0..) |e, i| {
                if (i > 0) try out.append(a, ',');
                try writeString(out, a, e.key);
                try out.append(a, ':');
                try write(out, a, e.value);
            }
            try out.append(a, '}');
        },
    }
}

pub fn stringify(a: Allocator, v: Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try write(&out, a, v);
    return out.toOwnedSlice(a);
}

/// Indented output for debugging (`json.dumps(indent=2)`)
pub fn writePretty(out: *std.ArrayList(u8), a: Allocator, v: Value, indent: usize) Allocator.Error!void {
    switch (v) {
        .array => |arr| {
            if (arr.items.len == 0) return out.appendSlice(a, "[]");
            try out.appendSlice(a, "[\n");
            for (arr.items, 0..) |item, i| {
                try out.appendNTimes(a, ' ', indent + 2);
                try writePretty(out, a, item, indent + 2);
                if (i + 1 < arr.items.len) try out.append(a, ',');
                try out.append(a, '\n');
            }
            try out.appendNTimes(a, ' ', indent);
            try out.append(a, ']');
        },
        .object => |o| {
            if (o.entries.items.len == 0) return out.appendSlice(a, "{}");
            try out.appendSlice(a, "{\n");
            for (o.entries.items, 0..) |e, i| {
                try out.appendNTimes(a, ' ', indent + 2);
                try writeString(out, a, e.key);
                try out.appendSlice(a, ": ");
                try writePretty(out, a, e.value, indent + 2);
                if (i + 1 < o.entries.items.len) try out.append(a, ',');
                try out.append(a, '\n');
            }
            try out.appendNTimes(a, ' ', indent);
            try out.append(a, '}');
        },
        else => try write(out, a, v),
    }
}

// --------------------------------------------------------------------------
// Parser (JSON5 superset of JSON)

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
            return .{ .int = if (neg) -v else v };
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
            if (std.fmt.parseInt(i64, text, 10)) |v| return .{ .int = v } else |_| {}
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
        var obj: Object = .{};
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
        var arr: std.ArrayList(Value) = .empty;
        while (true) {
            try p.skipWs();
            if (p.pos >= p.src.len) return p.fail();
            if (p.src[p.pos] == ']') {
                p.pos += 1;
                break;
            }
            try arr.append(p.a, try p.parseValue());
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

test "json round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a, "{\"a\": [1, 2.5, \"x\\u00e9\"], 'b': true, c: null, /* c */ \"d\": {},}");
    const out = try stringify(a, v);
    try std.testing.expectEqualStrings("{\"a\":[1,2.5,\"x\\u00e9\"],\"b\":true,\"c\":null,\"d\":{}}", out);
    const s = try from(a, .{ .label = "x", .n = @as(i64, 3), .opt = @as(?i64, null) });
    try std.testing.expectEqualStrings("{\"label\":\"x\",\"n\":3,\"opt\":null}", try stringify(a, s));
}

test "from omits null defaults; to decodes" {
    const T = struct {
        a: i64,
        b: ?[]const u8 = null,
        c: ?i64,
        d: []const []const u8 = &.{},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try stringify(a, try from(a, T{ .a = 1, .c = null }));
    try std.testing.expectEqualStrings("{\"a\":1,\"c\":null,\"d\":[]}", out);
    const v = try parse(a, "{\"a\":2,\"b\":\"x\",\"c\":3,\"d\":[\"p\",\"q\"],\"extra\":true}");
    const t = try to(T, a, v);
    try std.testing.expectEqual(@as(i64, 2), t.a);
    try std.testing.expectEqualStrings("x", t.b.?);
    try std.testing.expectEqual(@as(?i64, 3), t.c);
    try std.testing.expectEqualStrings("q", t.d[1]);
    try std.testing.expectError(error.InvalidParams, to(T, a, try parse(a, "{\"b\":\"x\"}")));
    try std.testing.expectError(error.InvalidParams, to(T, a, try parse(a, "{\"a\":\"s\",\"c\":1}")));
}
