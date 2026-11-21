//! Intel ifx's polymorphic objects in `zfls dap`'s gdb backend (Linux):
//! ifx's DWARF gives `class(point) :: t` as a `point`, and `class(point)
//! :: ts(:)` as a `point` too, at their data. Their descriptor (located by
//! `info address`: a dummy's `DW_OP_fbreg N; DW_OP_deref; DW_OP_deref`, a
//! static variable's address, a local's place in the frame) holds the
//! data's address, the dynamic type's size, the rank (word 4), three words
//! per dimension (extent, stride in bytes, lower bound) and then, at word
//! 6 + 3·rank, the type's record, whose first word points to its name
//! (`GRID#TAGGED`), as on Windows (values.zig). gdb's Python (ifx_class.py)
//! sets a convenience variable to the object as one of that type: a
//! pointer to it, or for an array the contiguous array with its bounds
//! (not of a type with allocatable components, gdb's `dynamic`). ifx
//! 2026.2, gdb 15.1, Ubuntu 24.04 (#667).

const std = @import("std");
const Allocator = std.mem.Allocator;

const script = @embedFile("ifx_class.py");

/// The gdb command that sets `$name` to ifx's polymorphic object `expr` (a
/// variable's name) as its dynamic type, when that is not `declared` (or
/// it is an array); it prints `zfls-class TYPE`, `zfls-class TYPE (2)`
/// for an array (`result`)
pub fn command(a: Allocator, expr: []const u8, name: []const u8, declared: []const u8) ![]const u8 {
    const program = try a.print("{s}try:\n    zfls_ifx_class(E, N, D)\nexcept (gdb.error, gdb.MemoryError, RuntimeError, ValueError):\n    pass\n", .{script});
    return a.print("python exec({f}, {{'E': {f}, 'N': {f}, 'D': {f}}})", .{
        std.json.fmt(program, .{}), std.json.fmt(expr, .{}), std.json.fmt(name, .{}), std.json.fmt(declared, .{}),
    });
}

/// What `command` found: the dynamic type, and an array's bounds
pub const Found = struct { name: []const u8, bounds: ?[]const u8 };

/// The dynamic type that `command`'s output names, or null
pub fn result(output: []const u8) ?Found {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, l, "zfls-class ")) continue;
        const rest = l["zfls-class ".len..];
        if (rest.len == 0) return null;
        const space = std.mem.findScalar(u8, rest, ' ') orelse return .{ .name = rest, .bounds = null };
        return .{ .name = rest[0..space], .bounds = std.mem.trim(u8, rest[space..], " ") };
    }
    return null;
}

/// The declared type of a pointer target of ifx's polymorphic allocatable
/// array: `Type point, allocatable (1255:1254)` -> `point`
pub fn declaredName(target: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, target, "Type ")) return null;
    const rest = target["Type ".len..];
    const end = std.mem.findScalar(u8, rest, ',') orelse return null;
    if (!std.mem.startsWith(u8, rest[end..], ", allocatable")) return null;
    return if (end > 0) rest[0..end] else null;
}

test "ifx's polymorphic objects: the command and its result" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try command(a, "t", "zfls_1", "point");
    try std.testing.expect(std.mem.startsWith(u8, c, "python exec(\""));
    try std.testing.expect(std.mem.endsWith(u8, c, ", {'E': \"t\", 'N': \"zfls_1\", 'D': \"point\"})"));
    try std.testing.expect(std.mem.find(u8, c, "def zfls_ifx_class(E, N, D):") != null);
    try std.testing.expectEqualDeep(Found{ .name = "tagged", .bounds = null }, result("zfls-class tagged\n").?);
    try std.testing.expectEqualDeep(Found{ .name = "labeled", .bounds = "(2)" }, result("zfls-class labeled (2)\n").?);
    try std.testing.expectEqualDeep(Found{ .name = "labeled", .bounds = "(0:1,3)" }, result("x\r\nzfls-class labeled (0:1,3)\r\n").?);
    try std.testing.expect(result("") == null);
    try std.testing.expect(result("Traceback (most recent call last):\n") == null);
}

test "ifx's polymorphic allocatable array: its declared type" {
    try std.testing.expectEqualStrings("point", declaredName("Type point, allocatable (1255:1254)").?);
    try std.testing.expect(declaredName("Type point") == null);
    try std.testing.expect(declaredName("character*7") == null);
}
