//! Values of the gdb backend of `zfls dap` that gdb does not show as
//! Fortran, read otherwise: a CHARACTER of kind 4, whose type gdb gives as
//! an array (`character(kind=4) (5)`) and whose text it cuts short at a
//! character beyond ASCII; read from memory.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../json.zig");
const fortran = @import("fortran.zig");
const session = @import("session.zig");
const Session = session.Session;
const gdb = @import("gdb.zig");
const gdb_variables = @import("gdb_variables.zig");

/// The longest string read from memory
const max_len = 4096;

/// A scalar CHARACTER of kind 4 (gdb's array type `t` of one dimension,
/// its length) as Fortran writes it (`4_'hëllo'`), read from the memory
/// of `expr`; null for any other type, or when it cannot be read
pub fn wideCharacter(s: *Session, a: Allocator, t: fortran.ArrayType, expr: ?[]const u8, frame: ?i64) !?[]const u8 {
    if (characterKind(t.element) != 4 or t.dims.len != 1) return null;
    const len = fortran.extent(t.dims[0]) orelse return null;
    const e = expr orelse return null;
    if (len > max_len) return null;
    const r = try gdb.request(s, a, "evaluate", try gdb_variables.evalArgs(a, try a.print("&{s}", .{e}), frame, "watch"));
    if (!gdb.isSuccess(r)) return null;
    const result = json.str(json.path(r, &.{ "body", "result" })) orelse return null;
    const address = fortran.addressOf(result[std.mem.find(u8, result, "0x") orelse return null ..]) orelse return null;
    const m = try gdb.request(s, a, "readMemory", .{ .memoryReference = address, .count = len * 4 });
    if (!gdb.isSuccess(m)) return null;
    const data = json.str(json.path(m, &.{ "body", "data" })) orelse return null;
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, decoder.calcSizeForSlice(data) catch return null);
    decoder.decode(bytes, data) catch return null;
    if (bytes.len != len * 4) return null;
    return try wideText(a, bytes);
}

/// The kind of gdb's CHARACTER type (`character(kind=4)`): 4; 1 for
/// `character*5`; 0 for another type
pub fn characterKind(t: []const u8) u32 {
    const prefix = "character(kind=";
    if (!std.mem.startsWith(u8, t, prefix)) return if (std.mem.startsWith(u8, t, "character")) 1 else 0;
    const end = std.mem.findScalarPos(u8, t, prefix.len, ')') orelse return 0;
    return std.fmt.parseInt(u32, t[prefix.len..end], 10) catch 0;
}

/// Characters of 4 bytes (UTF-32, little-endian) as a Fortran literal of
/// kind 4 in UTF-8: `4_'hëllo'`, a `'` doubled, an invalid one as U+FFFD
pub fn wideText(a: Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "4_'");
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 4) {
        const c = std.mem.readInt(u32, bytes[i..][0..4], .little);
        const cp: u21 = if (c <= 0x10FFFF and !(c >= 0xD800 and c <= 0xDFFF)) @intCast(c) else 0xFFFD;
        if (cp == '\'') try out.append(a, '\'');
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(a, buf[0..n]);
    }
    try out.append(a, '\'');
    return out.items;
}

test "a CHARACTER of kind 4 from its bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: [20]u8 = undefined;
    for ([_]u32{ 'h', 0xEB, 'l', 'l', 'o' }, 0..) |c, k| std.mem.writeInt(u32, b[k * 4 ..][0..4], c, .little);
    try std.testing.expectEqualStrings("4_'hëllo'", try wideText(a, &b));
    std.mem.writeInt(u32, b[0..4], '\'', .little);
    std.mem.writeInt(u32, b[4..8], 0xD800, .little);
    try std.testing.expectEqualStrings("4_'''\u{FFFD}'", try wideText(a, b[0..8]));
    try std.testing.expectEqual(@as(u32, 4), characterKind("character(kind=4)"));
    try std.testing.expectEqual(@as(u32, 1), characterKind("character*5"));
    try std.testing.expectEqual(@as(u32, 0), characterKind("real(kind=4)"));
}
