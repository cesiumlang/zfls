//! The functions of the Fortran runtimes that a program calls on an error
//! at run time (an array bound exceeded under `-fcheck=bounds`, a failed
//! allocation, an I/O error without `iostat=`) or on `ERROR STOP`, where
//! the exception filter **Fortran runtime errors** stops: gdb's and
//! lldb-dap's (`gdb_functions`), Windows's Debugger Engine's
//! (`engine_functions`). Pure: no debugger here.

const std = @import("std");
const builtin = @import("builtin");

/// A function of a runtime's errors, or of its `STOP` and `ERROR STOP`
pub const Function = struct {
    name: []const u8,
    /// Of `ERROR STOP` (else of an error at run time)
    error_stop: bool = false,
    /// A function of both `STOP` and `ERROR STOP`: which of its arguments
    /// (from 0) is the C `bool` that is true for `ERROR STOP`. The
    /// debugger stops only then: not at a plain `STOP`
    error_stop_argument: ?u2 = null,
};

/// LLVM Flang's `STOP` and `ERROR STOP`:
/// `_FortranAStopStatement(int code, bool isErrorStop, bool quiet)` and
/// `_FortranAStopStatementText(const char *, size_t, bool isErrorStop,
/// bool quiet)`
const flang_stops = [_]Function{
    .{ .name = "_FortranAStopStatement", .error_stop = true, .error_stop_argument = 1 },
    .{ .name = "_FortranAStopStatementText", .error_stop = true, .error_stop_argument = 2 },
};

/// gdb's and lldb-dap's: gfortran's, LLVM Flang's, Intel's.
///
/// Every error of Flang's runtime (an I/O error, a failed allocation,
/// `_FortranAReportFatalUserError`) prints its message through
/// `Fortran::runtime::Terminator::CrashHeader`, whose name gdb gives as
/// Microsoft's decorated one in a Windows program (gdb does not undecorate
/// it) and demangled elsewhere. `_FortranAReportFatalUserError` itself is
/// left out: it calls `CrashHeader`, so the program would stop twice.
pub const gdb_functions = [_]Function{
    .{ .name = "_gfortran_runtime_error" },
    .{ .name = "_gfortran_runtime_error_at" },
    .{ .name = "_gfortran_os_error" },
    .{ .name = "_gfortran_os_error_at" },
    .{ .name = "_gfortran_error_stop_string", .error_stop = true },
    .{ .name = "_gfortran_error_stop_numeric", .error_stop = true },
} ++ flang_stops ++ [_]Function{
    .{ .name = "?CrashHeader@Terminator@runtime@Fortran@@QEBAXXZ" },
    .{ .name = "Fortran::runtime::Terminator::CrashHeader" },
    .{ .name = "for__issue_diagnostic" },
};

/// Windows's Debugger Engine's: Intel's (what its runtime calls on a severe
/// error and on `ERROR STOP`), LLVM Flang's (the engine undecorates
/// Microsoft's names)
pub const engine_functions = [_]Function{
    .{ .name = "for__issue_diagnostic" },
    .{ .name = "for_error_stop", .error_stop = true },
    .{ .name = "for_error_stop8", .error_stop = true },
    .{ .name = "for_error_stop_int", .error_stop = true },
    .{ .name = "for_error_stop_int8", .error_stop = true },
} ++ flang_stops ++ [_]Function{
    .{ .name = "Fortran::runtime::Terminator::CrashHeader" },
};

/// A breakpoint of the engine on a function of `engine_functions`: its id
/// with its function
pub const EngineBreakpoint = struct { id: u32, function: Function };

/// Breakpoints on `functions`, each by `adder.add(name)` (its id), which
/// fails for a name the program does not have (a program links one
/// compiler's runtime): each kept with its own function, whichever failed
pub fn addEach(gpa: std.mem.Allocator, out: *std.ArrayList(EngineBreakpoint), functions: []const Function, adder: anytype) !void {
    for (functions) |f| {
        const id = adder.add(f.name) catch continue;
        try out.append(gpa, .{ .id = id, .function = f });
    }
}

/// The function of the breakpoint `id` of `added`
pub fn functionOf(added: []const EngineBreakpoint, id: u32) ?Function {
    for (added) |b| if (b.id == id) return b.function;
    return null;
}

/// The function of a name of `gdb_functions` or `engine_functions`
pub fn find(name: []const u8) ?Function {
    inline for (.{ gdb_functions, engine_functions }) |list| {
        for (list) |f| if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// Whether a function of the runtime is one of `ERROR STOP`
pub fn isErrorStop(name: []const u8) bool {
    return if (find(name)) |f| f.error_stop else false;
}

/// The register of an argument (from 0) of integer class at a function's
/// entry: by the calling convention of the target, which is zfls's own
/// (the debugger runs the program on this machine); null for a target
/// whose convention zfls does not know
pub fn argumentRegister(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag, index: u2) ?Register {
    return switch (arch) {
        .x86_64 => if (os == .windows)
            switch (index) {
                0 => .{ .gdb = "$cl", .engine = "rcx" },
                1 => .{ .gdb = "$dl", .engine = "rdx" },
                2 => .{ .gdb = "$r8l", .engine = "r8" },
                3 => .{ .gdb = "$r9l", .engine = "r9" },
            }
        else switch (index) {
            0 => .{ .gdb = "$dil", .engine = "rdi" },
            1 => .{ .gdb = "$sil", .engine = "rsi" },
            2 => .{ .gdb = "$dl", .engine = "rdx" },
            3 => .{ .gdb = "$cl", .engine = "rcx" },
        },
        .aarch64 => switch (index) {
            0 => .{ .gdb = "$w0", .engine = "x0" },
            1 => .{ .gdb = "$w1", .engine = "x1" },
            2 => .{ .gdb = "$w2", .engine = "x2" },
            3 => .{ .gdb = "$w3", .engine = "x3" },
        },
        else => null,
    };
}

/// A register of an argument: gdb's and lldb's of its low byte (on arm64,
/// which has none, of its low 32 bits: LLVM extends a `bool` argument to
/// them), as in an expression; the engine's name of all of it (of which
/// the low byte is the `bool`)
pub const Register = struct {
    gdb: []const u8,
    engine: [:0]const u8,
};

/// A breakpoint of gdb or lldb on a function of `gdb_functions`
pub const GdbBreakpoint = struct {
    name: []const u8,
    /// For a function of `STOP` and `ERROR STOP`: that its argument of
    /// `ERROR STOP` is true (a register, true when not 0, in C as in
    /// Fortran, gdb's language of the program)
    condition: ?[]const u8 = null,
};

/// gdb's and lldb's breakpoints on `gdb_functions` for a target: without
/// those that need a condition that zfls cannot write for it
pub fn gdbBreakpoints(comptime arch: std.Target.Cpu.Arch, comptime os: std.Target.Os.Tag) []const GdbBreakpoint {
    comptime {
        var out: []const GdbBreakpoint = &.{};
        for (gdb_functions) |f| {
            if (f.error_stop_argument) |i| {
                const r = argumentRegister(arch, os, i) orelse continue;
                out = out ++ [_]GdbBreakpoint{.{ .name = f.name, .condition = r.gdb }};
            } else out = out ++ [_]GdbBreakpoint{.{ .name = f.name }};
        }
        const final = out[0..out.len].*;
        return &final;
    }
}

/// gdb's and lldb's breakpoints on `gdb_functions` here (the debugger runs
/// the program on this machine)
pub const gdb_breakpoints = gdbBreakpoints(builtin.target.cpu.arch, builtin.target.os.tag);

test "the functions of the runtimes' errors and ERROR STOP" {
    try std.testing.expect(isErrorStop("_gfortran_error_stop_string"));
    try std.testing.expect(!isErrorStop("_gfortran_runtime_error_at"));
    try std.testing.expect(isErrorStop("_FortranAStopStatement"));
    try std.testing.expect(isErrorStop("_FortranAStopStatementText"));
    try std.testing.expect(isErrorStop("for_error_stop_int8"));
    try std.testing.expect(!isErrorStop("?CrashHeader@Terminator@runtime@Fortran@@QEBAXXZ"));
    try std.testing.expect(!isErrorStop("Fortran::runtime::Terminator::CrashHeader"));
    try std.testing.expect(!isErrorStop("for__issue_diagnostic"));
    try std.testing.expect(!isErrorStop("main"));
    // Flang's STOP functions take ERROR STOP as an argument; its errors
    // only through CrashHeader (not twice)
    try std.testing.expectEqual(@as(?u2, 1), find("_FortranAStopStatement").?.error_stop_argument);
    try std.testing.expectEqual(@as(?u2, 2), find("_FortranAStopStatementText").?.error_stop_argument);
    try std.testing.expect(find("_FortranAReportFatalUserError") == null);
    for (gdb_functions ++ engine_functions) |f| {
        if (f.error_stop_argument != null) try std.testing.expect(f.error_stop);
    }
}

test "the engine's breakpoints keep their functions when one is not found (#415)" {
    // ids as the engine gives them, one per breakpoint added; the first
    // name is not the program's
    const Adder = struct {
        next: u32 = 10,
        pub fn add(self: *@This(), name: []const u8) !u32 {
            if (std.mem.eql(u8, name, engine_functions[0].name)) return error.NotFound;
            self.next += 1;
            return self.next;
        }
    };
    var adder: Adder = .{};
    var added: std.ArrayList(EngineBreakpoint) = .empty;
    defer added.deinit(std.testing.allocator);
    try addEach(std.testing.allocator, &added, &engine_functions, &adder);
    try std.testing.expectEqual(engine_functions.len - 1, added.items.len);
    for (engine_functions[1..], 11..) |f, id| {
        try std.testing.expectEqualStrings(f.name, functionOf(added.items, @intCast(id)).?.name);
    }
    try std.testing.expect(functionOf(added.items, 10) == null);
    try std.testing.expect(functionOf(added.items, 99) == null);
}

test "the register of ERROR STOP's argument of Flang's STOP functions" {
    const Target = struct { std.Target.Cpu.Arch, std.Target.Os.Tag };
    const windows: Target = .{ .x86_64, .windows };
    const linux: Target = .{ .x86_64, .linux };
    const arm: Target = .{ .aarch64, .macos };
    const riscv: Target = .{ .riscv64, .linux };
    const of = struct {
        fn reg(t: Target, i: u2) ?Register {
            return argumentRegister(t[0], t[1], i);
        }
    };
    // _FortranAStopStatement: isErrorStop is the 2nd; StopStatementText: the 3rd
    try std.testing.expectEqualStrings("$dl", of.reg(windows, 1).?.gdb);
    try std.testing.expectEqualStrings("rdx", of.reg(windows, 1).?.engine);
    try std.testing.expectEqualStrings("$r8l", of.reg(windows, 2).?.gdb);
    try std.testing.expectEqualStrings("r8", of.reg(windows, 2).?.engine);
    try std.testing.expectEqualStrings("$sil", of.reg(linux, 1).?.gdb);
    try std.testing.expectEqualStrings("$dl", of.reg(linux, 2).?.gdb);
    try std.testing.expectEqualStrings("$w1", of.reg(arm, 1).?.gdb);
    try std.testing.expectEqualStrings("x2", of.reg(arm, 2).?.engine);
    try std.testing.expect(of.reg(riscv, 1) == null);
    // gdb's breakpoints: on Flang's STOP functions with a condition, the
    // others without
    const bps = comptime gdbBreakpoints(.x86_64, .windows);
    try std.testing.expectEqual(gdb_functions.len, bps.len);
    for (bps) |b| {
        if (std.mem.eql(u8, b.name, "_FortranAStopStatement")) {
            try std.testing.expectEqualStrings("$dl", b.condition.?);
        } else if (std.mem.eql(u8, b.name, "_FortranAStopStatementText")) {
            try std.testing.expectEqualStrings("$r8l", b.condition.?);
        } else try std.testing.expect(b.condition == null);
    }
    for (comptime gdbBreakpoints(.x86_64, .linux)) |b| if (std.mem.eql(u8, b.name, "_FortranAStopStatement"))
        try std.testing.expectEqualStrings("$sil", b.condition.?);
    // a target of no known convention: without Flang's STOP functions
    try std.testing.expectEqual(gdb_functions.len - 2, (comptime gdbBreakpoints(.riscv64, .linux)).len);
    for (comptime gdbBreakpoints(.riscv64, .linux)) |b| try std.testing.expect(b.condition == null);
}
