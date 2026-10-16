//! JSON of the Language Server Protocol, on `std.json`: messages are read
//! into a `std.json.Value`, request parameters decoded into the `lsp`
//! structures, and results converted to a `Value` written as compact,
//! ASCII-only text (like Python's `json.dumps(separators=(",", ":"))`).
//! Configuration files are JSON5 and have their own parser (`json5.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
pub const Array = std.json.Array;

// --------------------------------------------------------------------------
// Access

/// Member `key` of an object; null if missing or `v` is not an object
pub fn get(v: ?Value, key: []const u8) ?Value {
    const x = v orelse return null;
    return if (x == .object) x.object.get(key) else null;
}

/// Get a nested value through a path of object keys
pub fn path(v: ?Value, keys: []const []const u8) ?Value {
    var x = v;
    for (keys) |k| x = get(x, k);
    return x;
}

pub fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// An integer, or a float with an integral value
pub fn int(v: ?Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f and @abs(f) < 9e18) @intFromFloat(f) else null,
        else => null,
    };
}

/// The elements of an array; none if `v` is not an array
pub fn items(v: ?Value) []Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

// --------------------------------------------------------------------------
// Reading

pub const ParseError = error{ SyntaxError, OutOfMemory };

/// Parse a JSON-RPC message. Like Python's `json.loads`, it accepts escaped
/// unpaired UTF-16 surrogates, and bytes that are not UTF-8; both are read as
/// U+FFFD.
pub fn parse(a: Allocator, text: []const u8) ParseError!Value {
    return parseStrict(a, text) catch |e| switch (e) {
        error.OutOfMemory => e,
        error.SyntaxError => parseStrict(a, (try replaceInvalid(a, text)) orelse return e),
    };
}

fn parseStrict(a: Allocator, text: []const u8) ParseError!Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .duplicate_field_behavior = .use_last }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SyntaxError,
    };
}

/// `text` with invalid UTF-8 bytes and escaped unpaired surrogates replaced
/// by U+FFFD, or null if there are none
fn replaceInvalid(a: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    const utf8 = try validUtf8(a, text);
    var out: std.ArrayList(u8) = .empty;
    var changed = utf8.ptr != text.ptr;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, utf8, i, '\\')) |bs| {
        try out.appendSlice(a, utf8[i..bs]);
        // length of the escape: 2, 6 for `\uXXXX`, 12 for a surrogate pair,
        // 0 for an unpaired surrogate
        const n: usize = if (escapedUnit(utf8, bs)) |u| switch (u) {
            0xD800...0xDBFF => if (isLowSurrogate(escapedUnit(utf8, bs + 6))) 12 else 0,
            0xDC00...0xDFFF => 0,
            else => 6,
        } else 2;
        if (n == 0) {
            try out.appendSlice(a, "\\ufffd");
            changed = true;
            i = bs + 6;
        } else {
            const end = @min(bs + n, utf8.len);
            try out.appendSlice(a, utf8[bs..end]);
            i = end;
        }
    }
    try out.appendSlice(a, utf8[i..]);
    return if (changed) out.items else null;
}

/// The code unit of the `\uXXXX` escape at `text[i..]`
fn escapedUnit(text: []const u8, i: usize) ?u16 {
    if (i + 6 > text.len or text[i] != '\\' or text[i + 1] != 'u') return null;
    return std.fmt.parseInt(u16, text[i + 2 .. i + 6], 16) catch null;
}

fn isLowSurrogate(unit: ?u16) bool {
    const u = unit orelse return false;
    return u >= 0xDC00 and u <= 0xDFFF;
}

pub const DecodeError = error{ InvalidParams, OutOfMemory };

/// Decode request parameters into `T` with `std.json.parseFromValueLeaky`.
/// Absent fields take their default, unknown fields are ignored, and `null`
/// stands for an empty object; a value that does not fit is an error.
pub fn decode(comptime T: type, a: Allocator, v: Value) DecodeError!T {
    const src: Value = if (v == .null) .{ .object = .empty } else v;
    return std.json.parseFromValueLeaky(T, a, src, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidParams,
    };
}

// --------------------------------------------------------------------------
// Writing

/// Convert a Zig value into a JSON `Value`. Structs become objects with
/// their fields in declaration order; `null` optionals become JSON null,
/// except those of fields that default to `null`, which are left out. A
/// struct with a `toJson(self, a)` method converts itself. Strings that are
/// not valid UTF-8 are copied with U+FFFD for the invalid bytes.
pub fn from(a: Allocator, x: anytype) Allocator.Error!Value {
    const T = @TypeOf(x);
    if (T == Value) return x;
    switch (@typeInfo(T)) {
        .null => return .null,
        .bool => return .{ .bool = x },
        .int, .comptime_int => return .{ .integer = @intCast(x) },
        .float, .comptime_float => return .{ .float = x },
        .optional => return if (x) |v| from(a, v) else .null,
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return .{ .string = try validUtf8(a, x) };
            if (p.size == .one) {
                const C = @typeInfo(p.child);
                if (C == .array and C.array.child == u8) return .{ .string = try validUtf8(a, x) };
                return from(a, x.*);
            }
            if (p.size == .slice) return fromSlice(a, x);
            @compileError("unsupported pointer type " ++ @typeName(T));
        },
        .array => return fromSlice(a, &x),
        .@"struct" => |s| {
            if (@hasDecl(T, "toJson")) return x.toJson(a);
            var obj: ObjectMap = .empty;
            try obj.ensureTotalCapacity(a, s.field_names.len);
            inline for (s.field_names, s.field_types, s.field_attrs) |fname, ftype, fattrs| {
                const val = @field(x, fname);
                const omit = comptime @typeInfo(ftype) == .optional and !fattrs.@"comptime" and fattrs.defaultValue(ftype) != null;
                if (!(omit and val == null)) obj.putAssumeCapacityNoClobber(fname, try from(a, val));
            }
            return .{ .object = obj };
        },
        else => @compileError("unsupported type " ++ @typeName(T)),
    }
}

fn fromSlice(a: Allocator, xs: anytype) Allocator.Error!Value {
    var arr: Array = try .initCapacity(a, xs.len);
    for (xs) |item| arr.appendAssumeCapacity(try from(a, item));
    return .{ .array = arr };
}

/// `s`, or a copy with U+FFFD for each byte that is not part of valid UTF-8
pub fn validUtf8(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (len > 0 and i + len <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + len])) {
            try out.appendSlice(a, s[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

/// Compact text of a message
pub fn stringify(a: Allocator, v: Value) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{ .escape_unicode = true });
}

/// Indented text for logs and the debug CLI (`json.dumps(indent=2)`)
pub fn pretty(a: Allocator, v: Value) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2, .escape_unicode = true });
}

test "json round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a, "{\"a\": [1, 2.5, \"x\\u00e9\\ud83d\\ude00\"], \"b\": true, \"c\": null, \"d\": {}}");
    try std.testing.expectEqualStrings("{\"a\":[1,2.5,\"x\\u00e9\\ud83d\\ude00\"],\"b\":true,\"c\":null,\"d\":{}}", try stringify(a, v));
    try std.testing.expectEqual(@as(?i64, 1), int(items(get(v, "a"))[0]));
    try std.testing.expect(path(v, &.{ "d", "x" }) == null);
    const s = try from(a, .{ .label = "x\xff\x01", .n = @as(i64, 3), .opt = @as(?i64, null) });
    try std.testing.expectEqualStrings("{\"label\":\"x\\ufffd\\u0001\",\"n\":3,\"opt\":null}", try stringify(a, s));
}

test "parse replaces unpaired surrogates and invalid UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a, "[\"\\ud800x\", \"\\udc00\", \"\\\\ud800\", \"a\xffb\", \"\\ud83d\\ude00\"]");
    try std.testing.expectEqualStrings("[\"\\ufffdx\",\"\\ufffd\",\"\\\\ud800\",\"a\\ufffdb\",\"\\ud83d\\ude00\"]", try stringify(a, v));
    try std.testing.expectError(error.SyntaxError, parse(a, "{\"a\":"));
    try std.testing.expectError(error.SyntaxError, parse(a, "{\"a\":\"\\ud800\"} x"));
}

test "from omits null defaults; decode decodes" {
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
    const t = try decode(T, a, v);
    try std.testing.expectEqual(@as(i64, 2), t.a);
    try std.testing.expectEqualStrings("x", t.b.?);
    try std.testing.expectEqual(@as(?i64, 3), t.c);
    try std.testing.expectEqualStrings("q", t.d[1]);
    try std.testing.expectError(error.InvalidParams, decode(T, a, try parse(a, "{\"b\":\"x\"}")));
    try std.testing.expectError(error.InvalidParams, decode(T, a, try parse(a, "{\"a\":true,\"c\":1}")));
    try std.testing.expectError(error.InvalidParams, decode(struct { n: usize }, a, try parse(a, "{\"n\":-1}")));
    const D = struct { x: ?i64 = null };
    try std.testing.expectEqual(@as(?i64, null), (try decode(D, a, .null)).x);
}
