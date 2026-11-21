//! The symbols that the compiler of the compiler check predefines
//! (compilers/predefined.zig), for zfls's preprocessor (`#ifdef
//! __INTEL_LLVM_COMPILER`, `#if __GNUC__ >= 9`) and Intel's `!DEC$ IF
//! DEFINED(_WIN32)`: gfortran's (#541), ifx's and ifort's (#509), asked
//! once for each executable, and again when its file changes or OpenMP's
//! conditional lines are turned on or off. `pp_defs` win over them.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compilers = @import("../compilers.zig");
const predefined = @import("../compilers/predefined.zig");
const compiler_version = @import("compiler_version.zig");
const args_mod = @import("compile_args.zig");
const compile = @import("compile.zig");

const typing = @import("../argcheck/typing.zig");

const Server = @import("../server.zig").Server;
const Macro = predefined.Macro;

/// What an executable predefines, kept with its stamp
pub const Known = struct { stamp: ?compiler_version.Stamp, openmp: bool, defs: []const Macro };

/// Adds the compiler check's compiler's symbols (of the free form's
/// compiler, else the fixed form's) to `self.pp_defs`, those of `pp_defs`
/// left as they are
pub fn add(self: *Server) !void {
    const fixed = args_mod.compilerOf(self, false) == null;
    const id = args_mod.compilerOf(self, fixed) orelse return;
    if (!predefined.asks(id)) return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const exes = try args_mod.executables(self, a, id, args_mod.compilerPath(self, fixed), null);
    const openmp = !self.s.disable_openmp_conditional;
    for (exes) |exe| {
        const defs = macrosOf(self, a, id, exe, openmp) orelse continue;
        const pa = self.pp_defs_arena.allocator();
        for (defs) |d| {
            if (self.pp_defs.contains(d.name)) continue;
            try self.pp_defs.put(pa, try pa.dupe(u8, d.name), .{ .value = try pa.dupe(u8, d.value) });
        }
        self.log.info("compiler_diagnostics: {d} predefined symbols of {s}", .{ defs.len, exe });
        return;
    }
}

/// Whether the compiler check's compiler has REAL(10): not Intel's, and
/// gfortran's when it predefines `__GFC_REAL_10__` (not on aarch64, #548);
/// else as gfortran and Flang have it on zfls's own platform
pub fn hasReal10(self: *const Server) bool {
    const fixed = args_mod.compilerOf(self, false) == null;
    const id = args_mod.compilerOf(self, fixed) orelse return typing.native_real10;
    return switch (id) {
        .ifx, .ifort => false,
        .gfortran => if (self.pp_defs.contains("__GFORTRAN__")) self.pp_defs.contains("__GFC_REAL_10__") else typing.native_real10,
        else => typing.native_real10,
    };
}

/// The symbols `exe` (of compiler `id`) predefines, null when it does not
/// run
fn macrosOf(self: *Server, a: Allocator, id: compilers.Id, exe: []const u8, openmp: bool) ?[]const Macro {
    const stamp = compiler_version.stampOf(self.io, a, exe, self.toolEnv());
    if (self.compiler_macros.get(exe)) |k| if (std.meta.eql(k.stamp, stamp) and k.openmp == openmp) return k.defs;
    const sa = self.arena.allocator();
    const defs = predefined.ask(a, sa, id, exe, .{
        .io = self.io,
        .env = self.toolEnv(),
        .work_dir = compile.cacheDir(self, a, "work") catch return null,
        .cwd = if (self.root_path.len > 0) self.root_path else null,
        .openmp = openmp,
    }) orelse return null;
    const key = sa.dupe(u8, exe) catch return defs;
    self.compiler_macros.put(sa, key, .{ .stamp = stamp, .openmp = openmp, .defs = defs }) catch {};
    return defs;
}
