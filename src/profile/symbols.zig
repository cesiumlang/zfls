//! Function names of code addresses of this process, from its own debug
//! info (the PDB next to the executable).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The name of the function containing `addr`, allocated from `arena`; a
/// return address (`is_return`) is looked up one byte earlier. Falls back
/// to the module name and the address.
pub fn name(io: Io, arena: Allocator, addr: usize, is_return: bool) Allocator.Error![]const u8 {
    const di = std.debug.getSelfDebugInfo() catch return unknown(io, arena, null, addr);
    const lookup = if (is_return and addr > 0) addr - 1 else addr;
    var list: std.ArrayList(std.debug.Symbol) = .empty;
    defer list.deinit(arena);
    di.getSymbols(io, arena, arena, lookup, false, &list) catch return unknown(io, arena, di, addr);
    if (list.items.len == 0) return unknown(io, arena, di, addr);
    const n = list.items[list.items.len - 1].name orelse return unknown(io, arena, di, addr);
    return arena.dupe(u8, n);
}

fn unknown(io: Io, arena: Allocator, di: ?*std.debug.SelfInfo, addr: usize) Allocator.Error![]const u8 {
    const module = if (di) |d| (d.getModuleName(io, addr) catch "?") else "?";
    return arena.print("{s}!0x{x}", .{ module, addr });
}
