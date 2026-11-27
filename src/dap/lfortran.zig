//! LFortran's programs in `zfls dap` (gdb and lldb-dap), as far as its
//! debug information goes: LFortran 0.69's DWARF says the language is C,
//! and has integer and real scalars only (arrays, derived types, CHARACTER
//! lengths and module variables: the CodeView build on Windows writes
//! them, run/lfortran_types.zig, engine_lfortran.zig; elsewhere #992).
//! Here which programs are LFortran's, and its temporaries, which the
//! Variables view leaves out.
//! Its runtime's functions of errors and ERROR STOP are runtime_errors.zig's.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const gdb_entry = @import("gdb_entry.zig");

/// A function of LFortran's runtime that every program of LFortran's calls
/// from its `main`: a program that names it is LFortran's
pub const program_symbol = "_lpython_call_initial_functions";

/// Whether the program at `program` (relative to `cwd`) is LFortran's
pub fn isProgram(io: Io, a: Allocator, program: ?[]const u8, cwd: ?[]const u8) bool {
    const p = program orelse return false;
    if (p.len == 0) return false;
    const path = if (cwd) |c| (if (std.Io.Dir.path.isAbsolute(p)) p else std.Io.Dir.path.join(a, &.{ c, p }) catch p) else p;
    return gdb_entry.programHas(io, path, program_symbol);
}

/// Whether a variable is one of LFortran's temporaries, which the program
/// never names: `__libasr_index_0_`, `__libasr__created__var__0__array_constructor_`,
/// `__1_k` (a loop's copy of `k`), `lfortran_implied_do_k`
pub fn isTemporary(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "__libasr") or std.mem.startsWith(u8, name, "lfortran_implied_do_")) return true;
    // `__` digits `_`
    if (!std.mem.startsWith(u8, name, "__")) return false;
    var i: usize = 2;
    while (i < name.len and std.ascii.isDigit(name[i])) i += 1;
    return i > 2 and i < name.len and name[i] == '_';
}

test "LFortran's temporaries" {
    // as lldb listed the main program of tests/dap/grid.f90 (LFortran 0.69.0)
    for ([_][]const u8{ "__1__libasr_index_", "__1__libasr_index_1", "__1_k", "__libasr__created__var__0__array_constructor_", "__libasr_created__array_section_subscript_", "__libasr_index_0_5", "__libasr_section_first_element_", "lfortran_implied_do_k", "__12_x" }) |name| {
        try std.testing.expect(isTemporary(name));
    }
    for ([_][]const u8{ "big", "k", "m", "nothing", "lfortran", "__", "__1", "__x_k", "_s", "implied_do_k" }) |name| {
        try std.testing.expect(!isTemporary(name));
    }
}

test "an LFortran program by its runtime's function" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lf", .data = "\x00__lpython_call_initial_functions\x00_main\x00" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gf", .data = "\x00MAIN__\x00_gfortran_set_args\x00" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = std.Io.Dir.path.dirname(try tmp.dir.realPathFileAlloc(io, "lf", a)).?;
    try std.testing.expect(isProgram(io, a, "lf", dir));
    try std.testing.expect(!isProgram(io, a, "gf", dir));
    try std.testing.expect(!isProgram(io, a, "none", dir));
    try std.testing.expect(!isProgram(io, a, null, dir));
}
