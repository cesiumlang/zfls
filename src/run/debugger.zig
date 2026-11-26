//! Which of `zfls dap`'s debuggers fits a program: by its debug
//! information and the platform. One rule, for `zfls/buildCommand` (by
//! the compiler) and `zfls dap` (by the program).

const std = @import("std");

/// The format of a program's debug information
pub const DebugInfo = enum {
    /// gfortran's, LLVM Flang's with `-gdwarf-4`, LFortran's on Linux and macOS
    dwarf,
    /// Microsoft's (a PDB): ifx's and ifort's on Windows, LLVM Flang's `-g` there
    pdb,
};

/// `zfls dap`'s debuggers: `--gdb`, `--lldb`, `--dbgeng`
pub const Debugger = enum { gdb, lldb, dbgeng };

/// Windows's Debugger Engine for Microsoft's debug information; for DWARF,
/// lldb-dap on macOS (gdb does not run on Apple Silicon and must be
/// code-signed on Intel), else gdb
pub fn fits(info: DebugInfo, os: std.Target.Os.Tag) Debugger {
    return switch (info) {
        .pdb => .dbgeng,
        .dwarf => if (os == .macos) .lldb else .gdb,
    };
}

test "the debugger that fits a program" {
    try std.testing.expectEqual(Debugger.dbgeng, fits(.pdb, .windows));
    try std.testing.expectEqual(Debugger.gdb, fits(.dwarf, .windows));
    try std.testing.expectEqual(Debugger.gdb, fits(.dwarf, .linux));
    try std.testing.expectEqual(Debugger.lldb, fits(.dwarf, .macos));
}
