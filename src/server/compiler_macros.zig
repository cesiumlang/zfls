//! The symbols that the compiler of the compiler check predefines
//! (compilers/predefined.zig), for zfls's preprocessor (`#ifdef
//! __INTEL_LLVM_COMPILER`, `#if __GNUC__ >= 9`) and Intel's `!DEC$ IF
//! DEFINED(_WIN32)`: gfortran's (#541), ifx's and ifort's (#509), asked
//! once for each executable and option set, and again when its file
//! changes or OpenMP's conditional lines are turned on or off. `pp_defs`
//! win over them. Those of the free form's compiler are in `pp_defs`; a file
//! whose compiler or options differ (the fixed form's compiler, its
//! command's `-O2`) gets its own (`defsFor`, #657).
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compilers = @import("../compilers.zig");
const predefined = @import("../compilers/predefined.zig");
const pp = @import("../preprocessor.zig");
const parser = @import("../parser.zig");
const project = @import("../project.zig");
const compiler_version = @import("compiler_version.zig");
const args_mod = @import("compile_args.zig");
const compile = @import("compile.zig");

const typing = @import("../argcheck/typing.zig");

const Server = @import("../server.zig").Server;
const Macro = predefined.Macro;
const FortranFile = parser.FortranFile;

/// What an executable predefines with some options, kept with its stamp
pub const Known = struct { stamp: ?compiler_version.Stamp, openmp: bool, defs: []const Macro };

/// The symbols of the compiler in `pp_defs`, and what they are of
pub const Default = struct { key: []const u8 = "", defs: []const Macro = &.{} };

/// A compiler, the executables to try and the options that change what it
/// predefines; `key` names the three
const Probe = struct { id: compilers.Id, exes: []const []const u8, args: []const []const u8, key: []const u8 };

/// The probe of the compiler of form `fixed`, with `cmd` (a file's
/// command) or `compiler_args`; null when no compiler zfls asks is set
fn probeOf(self: *Server, a: Allocator, fixed: bool, cmd: ?project.Command) !?Probe {
    const id = args_mod.compilerOf(self, fixed) orelse return null;
    if (!predefined.asks(id)) return null;
    const exes = try args_mod.executables(self, a, id, args_mod.compilerPath(self, fixed), cmd);
    const given: []const []const u8 = args_mod.userArgs(self, fixed) orelse if (cmd) |c| (if (c.args.len > 0) c.args[1..] else &.{}) else &.{};
    const args = try predefined.relevantArgs(a, id, given);
    var key: std.ArrayList(u8) = .empty;
    try key.print(a, "{s}", .{@tagName(id)});
    for (exes) |e| try key.print(a, "\x00{s}", .{e});
    try key.append(a, 1);
    for (args) |x| try key.print(a, "\x00{s}", .{x});
    return .{ .id = id, .exes = exes, .args = args, .key = key.items };
}

/// Adds the compiler check's compiler's symbols (of the free form's
/// compiler, else the fixed form's) to `self.pp_defs`, those of `pp_defs`
/// left as they are
pub fn add(self: *Server) !void {
    self.default_macros = .{};
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const fixed = args_mod.compilerOf(self, false) == null;
    const p = (try probeOf(self, a, fixed, null)) orelse return;
    const pa = self.pp_defs_arena.allocator();
    const found = macrosOf(self, a, p) orelse return;
    for (found.defs) |d| {
        if (self.pp_defs.contains(d.name)) continue;
        try self.pp_defs.put(pa, try pa.dupe(u8, d.name), .{ .value = try pa.dupe(u8, d.value) });
    }
    self.default_macros = .{ .key = try pa.dupe(u8, p.key), .defs = found.defs };
    self.log.info("compiler_diagnostics: {d} predefined symbols of {s}", .{ found.defs.len, found.exe });
}

/// The definitions to preprocess `f` with: `pp_defs`, with the symbols of
/// `f`'s own compiler and options for those of `pp_defs`'s compiler when
/// they differ (in `a`). Sets how its preprocessor reads `#if` (#658).
pub fn defsFor(self: *Server, a: Allocator, f: *FortranFile) !*const pp.Defs {
    const fixed = f.declared_fixed;
    const compiler = args_mod.compilerOf(self, fixed);
    f.pp_dialect = if (compiler) |id| dialectOf(id) else .any;
    if (compiler == null) return &self.pp_defs;
    const cmd = try args_mod.commandOf(self, a, f, args_mod.userArgs(self, fixed));
    const p = (try probeOf(self, a, fixed, cmd)) orelse return &self.pp_defs;
    if (std.mem.eql(u8, p.key, self.default_macros.key)) return &self.pp_defs;
    const own = (macrosOf(self, a, p) orelse return &self.pp_defs).defs;
    const out = try a.create(pp.Defs);
    out.* = try pp.cloneDefs(a, &self.pp_defs);
    for (self.default_macros.defs) |m| {
        if (userDefines(self, m.name)) continue;
        const d = out.get(m.name) orelse continue;
        // unless a file has defined it otherwise
        if (d.args == null and std.mem.eql(u8, d.value, m.value)) _ = out.orderedRemove(m.name);
    }
    for (own) |m| if (!userDefines(self, m.name)) try out.put(a, m.name, .{ .value = m.value });
    return out;
}

/// How compiler `id`'s preprocessor reads `#if`
fn dialectOf(id: compilers.Id) pp.Dialect {
    return switch (id) {
        .ifx, .ifort => .intel,
        .gfortran => .gnu,
        else => .any,
    };
}

/// Whether `pp_defs` (the setting) defines `name`
fn userDefines(self: *const Server, name: []const u8) bool {
    for (self.s.pp_defs.items) |d| if (std.mem.eql(u8, d.name, name)) return true;
    return false;
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

/// The symbols of the first executable of `p` that runs, with its options
/// (else without them, which it may not take), and that executable; null
/// when none runs
fn macrosOf(self: *Server, a: Allocator, p: Probe) ?struct { defs: []const Macro, exe: []const u8 } {
    const openmp = !self.s.disable_openmp_conditional;
    for (p.exes) |exe| {
        const defs = macrosOfExe(self, a, p.id, exe, p.args, openmp) orelse
            (if (p.args.len > 0) macrosOfExe(self, a, p.id, exe, &.{}, openmp) else null) orelse continue;
        return .{ .defs = defs, .exe = exe };
    }
    return null;
}

/// The symbols `exe` (of compiler `id`) predefines with `args`, null when
/// it does not run
fn macrosOfExe(self: *Server, a: Allocator, id: compilers.Id, exe: []const u8, args: []const []const u8, openmp: bool) ?[]const Macro {
    const stamp = compiler_version.stampOf(self.io, a, exe, self.toolEnv());
    var key: std.ArrayList(u8) = .empty;
    key.appendSlice(a, exe) catch return null;
    for (args) |x| key.print(a, "\x00{s}", .{x}) catch return null;
    if (self.compiler_macros.get(key.items)) |k| if (std.meta.eql(k.stamp, stamp) and k.openmp == openmp) return k.defs;
    const work_dir = compile.cacheDir(self, a, "work") catch return null;
    // not before the workspace's root is known, without a cache directory:
    // Intel's probe file would go where zfls runs
    if ((id == .ifx or id == .ifort) and !std.Io.Dir.path.isAbsolute(work_dir)) return null;
    const sa = self.arena.allocator();
    const defs = predefined.ask(a, sa, id, exe, .{
        .io = self.io,
        .env = self.toolEnv(),
        .work_dir = work_dir,
        .cwd = if (self.root_path.len > 0) self.root_path else null,
        .openmp = openmp,
        .args = args,
    }) orelse return null;
    const k = sa.dupe(u8, key.items) catch return defs;
    self.compiler_macros.put(sa, k, .{ .stamp = stamp, .openmp = openmp, .defs = defs }) catch {};
    return defs;
}
