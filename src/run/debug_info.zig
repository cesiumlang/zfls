//! A program's debug information, from its file: DWARF (an ELF or a
//! Mach-O, or a PE with `.debug_info`), or Microsoft's (a PE whose debug
//! directory has a CodeView record, which names its PDB). LLVM Flang's
//! `-gdwarf-4 -Wl,-debug:dwarf` writes both: DWARF wins, for gdb.

const std = @import("std");
const debugger = @import("debugger.zig");
const fsio = @import("../fsio.zig");
const Io = std.Io;
const DebugInfo = debugger.DebugInfo;

/// The debug information of the program at `path`; null when the file is
/// not read or has none that zfls knows
pub fn ofFile(io: Io, path: []const u8) ?DebugInfo {
    const file = fsio.openFile(io, path) catch return null;
    defer file.close(io);
    return classify(FileReader{ .file = file, .io = io });
}

const FileReader = struct {
    file: Io.File,
    io: Io,

    fn read(r: FileReader, buf: []u8, offset: u64) usize {
        return r.file.readPositionalAll(r.io, buf, offset) catch 0;
    }
};

const SliceReader = struct {
    bytes: []const u8,

    fn read(r: SliceReader, buf: []u8, offset: u64) usize {
        if (offset >= r.bytes.len) return 0;
        const n = @min(buf.len, r.bytes.len - offset);
        @memcpy(buf[0..n], r.bytes[offset..][0..n]);
        return n;
    }
};

/// The debug information of the file `r` reads (`read(buf, offset)`: the
/// bytes read)
fn classify(r: anytype) ?DebugInfo {
    var head: [4]u8 = undefined;
    if (r.read(&head, 0) < 4) return null;
    if (std.mem.eql(u8, &head, "\x7fELF")) return .dwarf;
    const magic = std.mem.readInt(u32, &head, .little);
    // Mach-O, 32 or 64 bits, either order, and universal
    for ([_]u32{ 0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xbebafeca }) |m| if (magic == m) return .dwarf;
    if (std.mem.eql(u8, head[0..2], "MZ")) return pe(r);
    return null;
}

fn int(comptime T: type, r: anytype, offset: u64) ?T {
    var buf: [@sizeOf(T)]u8 = undefined;
    if (r.read(&buf, offset) < buf.len) return null;
    return std.mem.readInt(T, &buf, .little);
}

const Section = struct { va: u32, raw_size: u32, raw: u32 };

/// A PE: DWARF when it has `.debug_info`, else Microsoft's when its debug
/// directory has a CodeView record
fn pe(r: anytype) ?DebugInfo {
    const nt: u64 = int(u32, r, 0x3c) orelse return null;
    var sig: [4]u8 = undefined;
    if (r.read(&sig, nt) < 4 or !std.mem.eql(u8, &sig, "PE\x00\x00")) return null;
    const coff = nt + 4;
    const sections = int(u16, r, coff + 2) orelse return null;
    const symtab = int(u32, r, coff + 8) orelse return null;
    const symbols = int(u32, r, coff + 12) orelse return null;
    const opt = coff + 20;
    const opt_size = int(u16, r, coff + 16) orelse return null;
    // the debug directory: entry 6 of the data directories
    const pe32_plus = (int(u16, r, opt) orelse return null) == 0x20b;
    const dirs = opt + @as(u64, if (pe32_plus) 112 else 96);
    const count = int(u32, r, opt + @as(u64, if (pe32_plus) 108 else 92)) orelse 0;
    const debug_rva = if (count > 6) int(u32, r, dirs + 6 * 8) orelse 0 else 0;
    const debug_size = if (count > 6) int(u32, r, dirs + 6 * 8 + 4) orelse 0 else 0;
    var debug_at: ?u64 = null;
    var i: u64 = 0;
    while (i < sections) : (i += 1) {
        const at = opt + opt_size + i * 40;
        var name: [8]u8 = undefined;
        if (r.read(&name, at) < 8) return null;
        if (isDwarfSection(r, &name, @as(u64, symtab) + @as(u64, symbols) * 18)) return .dwarf;
        const s: Section = .{
            .va = int(u32, r, at + 12) orelse return null,
            .raw_size = int(u32, r, at + 16) orelse return null,
            .raw = int(u32, r, at + 20) orelse return null,
        };
        if (debug_size > 0 and debug_rva >= s.va and debug_rva < s.va + s.raw_size) debug_at = s.raw + (debug_rva - s.va);
    }
    // its entries: 28 bytes, the type at 12; 2 is CodeView
    const start = debug_at orelse return null;
    var e: u64 = 0;
    while (e + 28 <= debug_size) : (e += 28) {
        if (int(u32, r, start + e + 12) == 2) return .pdb;
    }
    return null;
}

/// Whether a section's name (`/N`: at offset N of the string table, at
/// `strings`, for names longer than 8 bytes) is `.debug_info`
fn isDwarfSection(r: anytype, name: *const [8]u8, strings: u64) bool {
    const want = ".debug_info";
    if (name[0] != '/') return false;
    const len = std.mem.findScalar(u8, name, 0) orelse 8;
    const offset = std.fmt.parseInt(u32, name[1..len], 10) catch return false;
    var buf: [want.len + 1]u8 = undefined;
    if (r.read(&buf, strings + offset) < buf.len) return false;
    return std.mem.eql(u8, buf[0..want.len], want) and buf[want.len] == 0;
}

const testing = std.testing;

/// A PE32+ with `sections` (name, the section's bytes), its debug
/// directory in the last one when `codeview` is not null
fn testPe(a: std.mem.Allocator, names: []const []const u8, codeview: ?u32) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendNTimes(a, 0, 0x80);
    @memcpy(b.items[0..2], "MZ");
    std.mem.writeInt(u32, b.items[0x3c..][0..4], 0x80, .little);
    try b.appendSlice(a, "PE\x00\x00");
    const coff = b.items.len;
    try b.appendNTimes(a, 0, 20 + 240);
    std.mem.writeInt(u16, b.items[coff + 2 ..][0..2], @intCast(names.len), .little);
    std.mem.writeInt(u16, b.items[coff + 16 ..][0..2], 240, .little);
    const opt = coff + 20;
    std.mem.writeInt(u16, b.items[opt..][0..2], 0x20b, .little);
    std.mem.writeInt(u32, b.items[opt + 108 ..][0..4], 16, .little);
    const table = b.items.len;
    try b.appendNTimes(a, 0, names.len * 40);
    // the string table after the section table, no symbols
    const strings = b.items.len;
    std.mem.writeInt(u32, b.items[coff + 8 ..][0..4], @intCast(strings), .little);
    try b.appendNTimes(a, 0, 4);
    for (names, 0..) |n, i| {
        const at = table + i * 40;
        if (n.len <= 8) {
            @memcpy(b.items[at..][0..n.len], n);
        } else {
            const name = try a.print("/{d}", .{b.items.len - strings});
            @memcpy(b.items[at..][0..name.len], name);
            try b.appendSlice(a, n);
            try b.append(a, 0);
        }
        const raw = b.items.len;
        std.mem.writeInt(u32, b.items[at + 12 ..][0..4], @intCast(0x1000 * (i + 1)), .little);
        std.mem.writeInt(u32, b.items[at + 16 ..][0..4], 0x100, .little);
        std.mem.writeInt(u32, b.items[at + 20 ..][0..4], @intCast(raw), .little);
        try b.appendNTimes(a, 0, 0x100);
        if (codeview != null and i == names.len - 1) {
            std.mem.writeInt(u32, b.items[opt + 112 + 6 * 8 ..][0..4], @intCast(0x1000 * (i + 1)), .little);
            std.mem.writeInt(u32, b.items[opt + 112 + 6 * 8 + 4 ..][0..4], 28, .little);
            std.mem.writeInt(u32, b.items[raw + 12 ..][0..4], codeview.?, .little);
        }
    }
    return b.items;
}

test "a program's debug information, from its file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(DebugInfo.dwarf, classify(SliceReader{ .bytes = "\x7fELF\x02\x01" }));
    try testing.expectEqual(DebugInfo.dwarf, classify(SliceReader{ .bytes = "\xcf\xfa\xed\xfe\x07" }));
    try testing.expectEqual(null, classify(SliceReader{ .bytes = "#!/bin/sh\n" }));
    // ifx's: a CodeView record (type 2)
    try testing.expectEqual(DebugInfo.pdb, classify(SliceReader{ .bytes = try testPe(a, &.{ ".text", ".rdata" }, 2) }));
    // gfortran's (MinGW): DWARF, named through the string table
    try testing.expectEqual(DebugInfo.dwarf, classify(SliceReader{ .bytes = try testPe(a, &.{ ".text", ".debug_info", ".debug_line" }, null) }));
    // LLVM Flang's -gdwarf-4 -Wl,-debug:dwarf: both, and DWARF wins
    try testing.expectEqual(DebugInfo.dwarf, classify(SliceReader{ .bytes = try testPe(a, &.{ ".text", ".debug_info", ".rdata" }, 2) }));
    // no debug information, or a debug directory of another kind
    try testing.expectEqual(null, classify(SliceReader{ .bytes = try testPe(a, &.{".text"}, null) }));
    try testing.expectEqual(null, classify(SliceReader{ .bytes = try testPe(a, &.{ ".text", ".rdata" }, 16) }));
    // cut short
    try testing.expectEqual(null, classify(SliceReader{ .bytes = (try testPe(a, &.{ ".text", ".rdata" }, 2))[0..0x90] }));
}
