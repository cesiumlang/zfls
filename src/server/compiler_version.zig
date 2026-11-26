//! The version of the compiler of the compiler check (compile.zig), for
//! the options that differ between its releases and for the .mod files,
//! which those of another release may not read: LLVM Flang's and
//! gfortran's, from `--version`, asked once for each executable, and again
//! when the file at its path changes (its size or modification time: a
//! compiler upgraded in place, #427). With it, where Flang's intrinsic
//! modules are when its driver does not find them
//! (compilers/flang_modules.zig, #438).
//! Part of `Server` (server.zig): each function takes it as `self`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const compilers = @import("../compilers.zig");
const flang = @import("../compilers/flang.zig");
const flang_modules = @import("../compilers/flang_modules.zig");
const gfortran = @import("../compilers/gfortran.zig");
const intel = @import("../compilers/intel.zig");
const tools = @import("tools.zig");

const Server = @import("../server.zig").Server;
const fsio = @import("../fsio.zig");

/// What is known of the compiler that the check runs, the first of `exes`
/// that runs: for LLVM Flang and gfortran (Intel's: `intelOf`), else
/// nothing. Nothing too when none
/// runs or it does not say (no version-dependent options then). An
/// executable that did not run is asked again next time: it may run then
/// (a script made executable after zfls first asked at the start, #395).
pub fn of(self: *Server, a: Allocator, id: compilers.Id, exes: []const []const u8) Known {
    const none: Known = .{ .found = false, .version = null };
    if (id == .ifx or id == .ifort) return intelOf(self, a, exes);
    if (id != .flang and id != .gfortran) return none;
    for (exes) |exe| {
        const stamp = stampOf(self.io, a, exe, self.toolEnv());
        if (self.compiler_versions.get(exe)) |known| if (std.meta.eql(known.stamp, stamp)) {
            if (known.found) return known;
            continue;
        };
        var found = ask(self, a, id, exe);
        found.stamp = stamp;
        if (!found.ran) {
            if (found.found) return found;
            continue;
        }
        if (self.compiler_versions.getPtr(exe)) |old| {
            old.* = found;
        } else {
            const key = self.arena.allocator().dupe(u8, exe) catch return found;
            self.compiler_versions.put(self.arena.allocator(), key, found) catch {};
        }
        if (found.found) return found;
    }
    return none;
}

/// Intel's: where the modules of the first of `exes` that is there are,
/// when its driver does not look there (`intel.moduleDir`)
fn intelOf(self: *Server, a: Allocator, exes: []const []const u8) Known {
    for (exes) |exe| {
        const path = pathOf(self.io, a, exe, self.toolEnv()) orelse continue;
        const dir = intel.moduleDir(self.io, a, path) catch null;
        if (dir) |d| self.log.info("compiler_diagnostics: {s}'s modules are not where its driver looks: {s}", .{ path, d });
        return .{ .found = true, .version = null, .intrinsic_modules = dir };
    }
    return .{ .found = false, .version = null };
}

/// What `exe --version` said, whether `exe` was there, and the file it
/// was; the directory of Flang's intrinsic modules to pass (the server's),
/// and where they are, passed or not (modfiles.zig); `ran`: false when
/// `exe` could not be run (not found, not executable), which `of` does not
/// keep (a compiler that hangs is kept: asked again, it would hang again)
pub const Known = struct { found: bool, version: ?u32, stamp: ?Stamp = null, intrinsic_modules: ?[]const u8 = null, module_dir: ?[]const u8 = null, ran: bool = true };

/// The size and modification time of an executable's file
pub const Stamp = struct { size: u64, mtime: i96 };

/// The stamp of the file that runs as `exe` (`pathOf`)
pub fn stampOf(io: Io, a: Allocator, exe: []const u8, env: ?*const std.process.Environ.Map) ?Stamp {
    const p = pathOf(io, a, exe, env) orelse return null;
    const st = fsio.statFile(io, p) catch return null;
    return .{ .size = st.size, .mtime = st.mtime.nanoseconds };
}

/// The file that runs as `exe`: the path itself (with `.exe`, `.cmd` or
/// `.bat` on Windows), else, for a name without a directory, the first of
/// the `PATH` of `env` that is a file; null when none is (or there is no
/// environment to search)
pub fn pathOf(io: Io, a: Allocator, exe: []const u8, env: ?*const std.process.Environ.Map) ?[]const u8 {
    const suffixes: []const []const u8 = if (builtin.target.os.tag == .windows) &.{ "", ".exe", ".cmd", ".bat" } else &.{""};
    if (std.mem.findAny(u8, exe, "/\\") != null) return fileOf(io, a, exe, suffixes);
    const e = env orelse return null;
    var it = std.mem.tokenizeScalar(u8, e.get("PATH") orelse "", std.Io.Dir.path.delimiter);
    while (it.next()) |dir| {
        const p = std.Io.Dir.path.join(a, &.{ dir, exe }) catch return null;
        if (fileOf(io, a, p, suffixes)) |f| return f;
    }
    return null;
}

fn fileOf(io: Io, a: Allocator, path: []const u8, suffixes: []const []const u8) ?[]const u8 {
    for (suffixes) |x| {
        const p = if (x.len == 0) path else a.print("{s}{s}", .{ path, x }) catch return null;
        const st = fsio.statFile(io, p) catch continue;
        if (st.kind != .file) continue;
        return p;
    }
    return null;
}

fn ask(self: *Server, a: Allocator, id: compilers.Id, exe: []const u8) Known {
    // in the workspace, not zfls's own directory: a compiler (or a script
    // standing for one) may write files where it runs
    const r = tools.run(a, self.io, .{
        .argv = &.{ exe, "--version" },
        .cwd = if (self.root_path.len > 0) self.root_path else null,
        .environ_map = self.toolEnv(),
        .timeout = tools.seconds(10),
    }) catch |e| return .{ .found = e != error.FileNotFound, .version = null, .ran = e == error.Timeout };
    if (id == .gfortran) {
        const version = gfortran.parseVersion(r.stdout) orelse gfortran.parseVersion(r.stderr);
        self.log.info("compiler_diagnostics: {s} is gfortran {?d}", .{ exe, version });
        return .{ .found = true, .version = version };
    }
    const version = flang.parseVersion(r.stdout) orelse flang.parseVersion(r.stderr);
    self.log.info("compiler_diagnostics: {s} is LLVM Flang {?d}", .{ exe, version });
    const modules = flang_modules.intrinsicModules(self.io, a, r.stdout) catch null;
    if (modules) |d| self.log.info("compiler_diagnostics: {s}'s intrinsic modules are not where its driver looks: -fintrinsic-modules-path {s}", .{ exe, d });
    const module_dir = flang_modules.moduleDir(self.io, a, r.stdout) catch null;
    const sa = self.arena.allocator();
    return .{
        .found = true,
        .version = version,
        .intrinsic_modules = if (modules) |d| sa.dupe(u8, d) catch null else null,
        .module_dir = if (module_dir) |d| sa.dupe(u8, d) catch null else null,
    };
}

test "an executable's stamp: its file, on the PATH, and none" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = if (builtin.target.os.tag == .windows) "fc.cmd" else "fc";
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "one" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.Io.Dir.path.join(a, &.{ dir, "fc" });
    const first = stampOf(io, a, path, null).?;
    try std.testing.expectEqual(@as(u64, 3), first.size);
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", dir);
    try std.testing.expectEqual(first, stampOf(io, a, "fc", &env).?);
    try std.testing.expect(stampOf(io, a, "fc", null) == null);
    try std.testing.expect(stampOf(io, a, "no-such-fc", &env) == null);
    // a new file at the same path: another stamp
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "two!" });
    try std.testing.expect(!std.meta.eql(first, stampOf(io, a, path, null).?));
}
