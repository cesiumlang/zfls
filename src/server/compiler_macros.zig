//! The symbols that the compiler of the compiler check predefines, for
//! zfls's preprocessor (`#ifdef __INTEL_LLVM_COMPILER`) and Intel's
//! `!DEC$ IF DEFINED(_WIN32)`: ifx's and ifort's, from `-fpp -E` of a probe
//! file that tests each name of `intel_names` (#509), asked once for each
//! executable, and again when its file changes, with OpenMP's option when
//! zfls reads OpenMP's conditional lines (`_OPENMP`). `pp_defs` win over
//! them.
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const sysinfo = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const compilers = @import("../compilers.zig");
const tools = @import("tools.zig");
const compiler_version = @import("compiler_version.zig");
const args_mod = @import("compile_args.zig");
const compile = @import("compile.zig");

const Server = @import("../server.zig").Server;

const is_windows = sysinfo.target.os.tag == .windows;

/// What an executable predefines, kept with its stamp
pub const Known = struct { stamp: ?compiler_version.Stamp, openmp: bool, defs: []const Macro };

pub const Macro = struct { name: []const u8, value: []const u8 };

/// The names Intel's compilers may predefine (ifx 2026.2 on Windows:
/// `__INTEL_COMPILER=20260200`, `_WIN32=1`, `_M_X64=100`, ...)
const intel_names = [_][]const u8{
    "__INTEL_COMPILER",      "__INTEL_LLVM_COMPILER", "__INTEL_COMPILER_BUILD_DATE", "__INTEL_COMPILER_UPDATE",
    "__INTEL_COMPILER_ARCH", "_MSC_VER",              "_WIN32",                      "_WIN64",
    "_M_X64",                "_M_AMD64",              "_M_IX86",                     "__x86_64__",
    "__x86_64",              "__amd64__",             "__aarch64__",                 "__linux__",
    "__linux",               "linux",                 "__unix__",                    "__unix",
    "unix",                  "__gnu_linux__",         "__ELF__",                     "__APPLE__",
    "__MACH__",              "_OPENMP",               "__INTEL_OFFLOAD",             "__SSE__",
    "__SSE2__",              "__AVX__",               "__AVX2__",                    "__AVX512F__",
};

/// Adds the compiler check's compiler's symbols (of the free form's
/// compiler, else the fixed form's) to `self.pp_defs`, those of `pp_defs`
/// left as they are
pub fn add(self: *Server) !void {
    const fixed = args_mod.compilerOf(self, false) == null;
    const id = args_mod.compilerOf(self, fixed) orelse return;
    if (id != .ifx and id != .ifort) return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const exes = try args_mod.executables(self, a, id, args_mod.compilerPath(self, fixed), null);
    const openmp = !self.s.disable_openmp_conditional;
    for (exes) |exe| {
        const defs = macrosOf(self, a, exe, openmp) orelse continue;
        const pa = self.pp_defs_arena.allocator();
        for (defs) |d| {
            if (self.pp_defs.contains(d.name)) continue;
            try self.pp_defs.put(pa, try pa.dupe(u8, d.name), .{ .value = try pa.dupe(u8, d.value) });
        }
        self.log.info("compiler_diagnostics: {d} predefined symbols of {s}", .{ defs.len, exe });
        return;
    }
}

/// The symbols `exe` predefines, null when it does not run
fn macrosOf(self: *Server, a: Allocator, exe: []const u8, openmp: bool) ?[]const Macro {
    const stamp = compiler_version.stampOf(self.io, a, exe, self.toolEnv());
    if (self.compiler_macros.get(exe)) |k| if (std.meta.eql(k.stamp, stamp) and k.openmp == openmp) return k.defs;
    const dir = compile.cacheDir(self, a, "work") catch return null;
    Io.Dir.cwd().createDirPath(self.io, dir) catch return null;
    const probe = std.Io.Dir.path.join(a, &.{ dir, "zfls_predefined.F90" }) catch return null;
    Io.Dir.cwd().writeFile(self.io, .{ .sub_path = probe, .data = probeText(a) catch return null }) catch return null;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, if (is_windows) &.{ exe, "/nologo", "/fpp", "/E" } else &.{ exe, "-fpp", "-E" }) catch return null;
    if (openmp) argv.append(a, if (is_windows) "/Qopenmp" else "-qopenmp") catch return null;
    argv.append(a, probe) catch return null;
    const r = tools.run(a, self.io, .{
        .argv = argv.items,
        .cwd = dir,
        .environ_map = tools.withExeDir(a, self.toolEnv(), exe) catch return null,
        .timeout = tools.seconds(20),
    }) catch return null;
    if (!r.term.success()) return null;
    const sa = self.arena.allocator();
    const defs = parseProbe(sa, r.stdout) catch return null;
    const key = sa.dupe(u8, exe) catch return defs;
    self.compiler_macros.put(sa, key, .{ .stamp = stamp, .openmp = openmp, .defs = defs }) catch {};
    return defs;
}

/// A file that writes `zfls_def I VALUE` for each name `intel_names[I]`
/// that is defined
fn probeText(a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (intel_names, 0..) |n, i| try out.print(a, "#ifdef {s}\nzfls_def {d} {s}\n#endif\n", .{ n, i, n });
    return out.items;
}

/// The symbols of the preprocessed probe file
fn parseProbe(a: Allocator, output: []const u8) ![]const Macro {
    var out: std.ArrayList(Macro) = .empty;
    var it = compilers.lines(output);
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, compilers.trimCr(raw), " \t");
        if (!std.mem.startsWith(u8, line, "zfls_def ")) continue;
        var words = std.mem.tokenizeScalar(u8, line["zfls_def ".len..], ' ');
        const i = std.fmt.parseInt(usize, words.next() orelse continue, 10) catch continue;
        if (i >= intel_names.len) continue;
        try out.append(a, .{ .name = intel_names[i], .value = try a.dupe(u8, std.mem.trim(u8, words.rest(), " ")) });
    }
    return out.items;
}

test "ifx's predefined symbols, from its preprocessed probe file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try probeText(a);
    try std.testing.expect(std.mem.startsWith(u8, text, "#ifdef __INTEL_COMPILER\nzfls_def 0 __INTEL_COMPILER\n#endif\n"));
    // ifx 2026.2.0 on Windows, `-fpp -E -Qopenmp` (an excerpt)
    const defs = try parseProbe(a, "# 1 \"zfls_predefined.F90\"\r\nzfls_def 0 20260200\r\nzfls_def 1 20260200\r\nzfls_def 6 1\r\n# 30\r\nzfls_def 8 100\r\nzfls_def 25 202011\r\nzfls_def 99 1\r\n");
    try std.testing.expectEqual(@as(usize, 5), defs.len);
    try std.testing.expectEqualStrings("__INTEL_COMPILER", defs[0].name);
    try std.testing.expectEqualStrings("20260200", defs[0].value);
    try std.testing.expectEqualStrings("_WIN32", defs[2].name);
    try std.testing.expectEqualStrings("_M_X64", defs[3].name);
    try std.testing.expectEqualStrings("100", defs[3].value);
    try std.testing.expectEqualStrings("_OPENMP", defs[4].name);
}
