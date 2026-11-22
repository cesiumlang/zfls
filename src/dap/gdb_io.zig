//! gdb's function `$_zfls_io_unhandled(flags, handled)` of `zfls dap`'s
//! gdb backend: that the `int` at address `flags` has none of the bits of
//! `handled`, for the condition of gfortran's I/O errors
//! (`runtime_errors.gdbIoCondition`). gdb parses a condition in the
//! language of the program when it has the program, Fortran for
//! gfortran's: there C's `*(int *)` finds `int` only in C's debug
//! information, which a program need not have (MSYS2's runtime has none),
//! and the breakpoint never stops (#776). A call parses alike in C and
//! Fortran.
//! Part of `Session` (session.zig): each function takes it as `s`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("../json.zig");
const Session = @import("session.zig").Session;
const gdb = @import("gdb.zig");

/// The function, in gdb's Python (little-endian: x86-64's and AArch64's,
/// the targets of `runtime_errors.pointerRegister`)
const python =
    \\import gdb
    \\class ZflsIoUnhandled(gdb.Function):
    \\    def __init__(self):
    \\        super().__init__('_zfls_io_unhandled')
    \\    def invoke(self, flags, handled):
    \\        m = gdb.selected_inferior().read_memory(int(flags), 4)
    \\        return (int.from_bytes(bytes(m), 'little') & int(handled)) == 0
    \\ZflsIoUnhandled()
    \\
;

/// gdb's command that defines the function
pub fn command(a: Allocator) ![]const u8 {
    return a.print("python exec({f})", .{std.json.fmt(python, .{})});
}

/// The function defined in gdb, before a condition calls it
pub fn define(s: *Session, a: Allocator) !void {
    const r = try gdb.request(s, a, "evaluate", .{ .expression = try command(a), .context = "repl" });
    if (!gdb.isSuccess(r)) s.log.warn("zfls dap: no $_zfls_io_unhandled: {s}", .{json.str(json.get(r, "message")) orelse "?"});
}

test "the command that defines $_zfls_io_unhandled" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try command(arena.allocator());
    try std.testing.expect(std.mem.startsWith(u8, c, "python exec(\"import gdb\\n"));
    try std.testing.expect(std.mem.find(u8, c, "super().__init__('_zfls_io_unhandled')") != null);
}
