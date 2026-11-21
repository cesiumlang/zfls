//! The command that builds a Fortran file into a program to run or debug
//! (`zfls/buildCommand`, `zfls build-command`): the compiler, its
//! arguments, the directory it runs in, its environment, the program, the
//! program's environment and the debugger that fits it. Every editor
//! builds a file the same way with it; the VS Code extension's Run and
//! Debug Fortran File run it as a task.

const std = @import("std");
const sysinfo = @import("builtin");
const compilers = @import("../compilers.zig");
const compiler_names = @import("../compiler_names.zig");
const executables = @import("../executables.zig");
const json = @import("../json.zig");
const paths = @import("../paths.zig");
const compiler = @import("compiler.zig");
const debugger = @import("debugger.zig");
const run_env = @import("env.zig");
const kit = @import("kit.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const Os = std.Target.Os.Tag;
const Var = run_env.Var;

const os = sysinfo.target.os.tag;

pub const Request = struct {
    /// The Fortran file (absolute); null: only what concerns the compiler
    /// (for a program built otherwise, such as by fpm)
    source: ?[]const u8 = null,
    /// The compiler: a name looked up on the `PATH`, or a path
    compiler: []const u8 = "gfortran",
    /// Where the compiler is: its file, or the directory that holds it
    /// (relative to `base_dir`)
    compiler_path: []const u8 = "",
    base_dir: ?[]const u8 = null,
    /// The build's options in place of the compiler's defaults
    args: ?[]const []const u8 = null,
    /// Where the build runs and the program goes; null: a directory of its
    /// own per source file in zfls's cache
    output_dir: ?[]const u8 = null,
};

/// Where the request is answered
pub const Context = struct {
    io: Io,
    /// The environment the compiler and lld-link are looked up in
    env: *const Environ.Map,
    /// The environment the additions (`env`, `runEnv`) are made to: `env`,
    /// or the values an editor gives in its place (such as `${env:Path}`)
    base_env: *const Environ.Map,
    /// zfls's cache directory (`paths.cacheDir`)
    cache_dir: ?[]const u8,
    /// zfls's ifx kit (`kit.find`)
    kit_dir: ?[]const u8,
};

/// Environment variables, as a JSON object of their values
pub const Vars = struct {
    items: []const Var = &.{},

    pub fn toJson(v: Vars, a: Allocator) !json.Value {
        var obj: json.ObjectMap = .empty;
        for (v.items) |x| try obj.put(a, x.name, .{ .string = x.value });
        return .{ .object = obj };
    }
};

/// The answer, as `zfls/buildCommand` gives it
pub const Answer = struct {
    /// The compiler's executable: the build's command
    compiler: []const u8,
    /// The compiler zfls knows it as (`gfortran`, `flang`, ...); null for
    /// another, built like gfortran
    name: ?[]const u8,
    /// The program's debug information: `dwarf` or `pdb`
    debugInfo: []const u8,
    /// The debugger of `zfls dap` that fits the program: `gdb`, `lldb` or
    /// `dbgeng`
    debugger: []const u8,
    /// The program's environment beyond the editor's: on Windows the
    /// compiler's directory first on the `PATH`, for its runtime libraries
    runEnv: Vars,
    /// The compiler's arguments
    args: ?[]const []const u8 = null,
    /// The directory the build runs in (module and object files go there)
    cwd: ?[]const u8 = null,
    /// The build's environment beyond the editor's
    env: ?Vars = null,
    program: ?[]const u8 = null,
    /// Why the build links otherwise than it could (no ifx kit, no lld-link)
    note: ?[]const u8 = null,
};

/// The answer, null when the compiler is not found. Creates the output
/// directory, and for LFortran on Windows the `link.cmd` in zfls's cache.
pub fn plan(a: Allocator, ctx: Context, r: Request) !?Answer {
    const exe = try executables.find(a, ctx.io, ctx.env, r.compiler, r.compiler_path, r.base_dir) orelse return null;
    const id = compiler_names.idOf(exe) orelse compiler_names.idOf(r.compiler);
    // LLVM Flang and LFortran on Windows link with lld-link when there is one
    const lld = if (os == .windows and (id == .flang or id == .lfortran)) try lldLink(a, ctx, exe) else null;
    const k = compiler.kind(id, os, lld != null);
    var ans: Answer = .{
        .compiler = exe,
        .name = if (id) |i| @tagName(i) else null,
        .debugInfo = @tagName(k.debug_info),
        .debugger = @tagName(debugger.fits(k.debug_info, os)),
        .runEnv = .{ .items = try runtimeEnv(a, ctx.base_env, os, paths.dirname(exe)) },
    };
    const source = r.source orelse return ans;
    const out_dir = r.output_dir orelse if (ctx.cache_dir) |c|
        try std.Io.Dir.path.join(a, &.{ c, "run", try outputName(a, source, os) })
    else
        paths.dirname(source);
    try Io.Dir.cwd().createDirPath(ctx.io, out_dir);
    const program = try std.Io.Dir.path.join(a, &.{ out_dir, try programName(a, source, os) });
    var note: ?[]const u8 = null;
    const link = try kitLink(a, ctx, id, lld, r.args, &note);
    ans.args = try compiler.buildArgs(a, k, source, program, r.args, link.args);
    ans.cwd = out_dir;
    ans.env = .{ .items = link.env };
    ans.program = program;
    ans.note = note;
    return ans;
}

/// The lld-link next to `exe` (conda-forge's `lld`), else on the `PATH`
fn lldLink(a: Allocator, ctx: Context, exe: []const u8) !?[]const u8 {
    return try executables.inDir(a, ctx.io, ctx.env, paths.dirname(exe), "lld-link") orelse
        try executables.onPath(a, ctx.io, ctx.env, "lld-link");
}

/// How LLVM Flang and LFortran link on Windows: with lld-link and the ifx
/// kit when both are there, outside a Visual Studio environment; `note`
/// says why not
fn kitLink(a: Allocator, ctx: Context, id: ?compilers.Id, lld: ?[]const u8, user_args: ?[]const []const u8, note: *?[]const u8) !kit.Link {
    const c = id orelse return .{};
    if (os != .windows or (c != .flang and c != .lfortran)) return .{};
    const label = if (c == .flang) "LLVM Flang" else "LFortran";
    const kit_dir = ctx.kit_dir orelse {
        note.* = try a.print("{s} links with Visual Studio's link: no ifx kit next to zfls", .{label});
        return .{};
    };
    const lld_link = lld orelse {
        note.* = try a.print("{s} links with Visual Studio's link: no lld-link next to it or on the PATH", .{label});
        return .{};
    };
    if (c == .flang) return try kit.flang(a, kit_dir, user_args, ctx.base_env) orelse .{};
    const cache = ctx.cache_dir orelse return .{};
    const link_dir = try std.Io.Dir.path.join(a, &.{ cache, "lfortran-link" });
    try writeIfChanged(a, ctx.io, link_dir, "link.cmd", try kit.linkScript(a, lld_link));
    return try kit.lfortran(a, kit_dir, link_dir, ctx.base_env) orelse .{};
}

fn writeIfChanged(a: Allocator, io: Io, dir: []const u8, name: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.path.join(a, &.{ dir, name });
    if (Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 16))) |old| {
        if (std.mem.eql(u8, old, data)) return;
    } else |_| {}
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = data });
}

/// On Windows, the compiler's directory first on the `PATH` of `env`, for
/// its runtime libraries (libgfortran-5.dll and the like), unless it is
/// there already
fn runtimeEnv(a: Allocator, env: *const Environ.Map, target: Os, dir: []const u8) ![]const Var {
    if (target != .windows or run_env.onPath(env, target, dir)) return &.{};
    return a.dupe(Var, &.{try run_env.prependPath(a, env, target, dir)});
}

/// The output directory's name for `source`: its stem and a hash of its
/// path (without case on Windows), so that files of the same name and
/// their module files do not collide
pub fn outputName(a: Allocator, source: []const u8, target: Os) ![]const u8 {
    var key: []const u8 = source;
    if (target == .windows) key = try std.ascii.allocLowerString(a, source);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return a.print("{s}-{s}", .{ stem(source, target), hex[0..10] });
}

/// The program's file name for `source`
pub fn programName(a: Allocator, source: []const u8, target: Os) ![]const u8 {
    return a.print("{s}{s}", .{ stem(source, target), if (target == .windows) ".exe" else "" });
}

/// `source`'s file name without its extension
fn stem(source: []const u8, target: Os) []const u8 {
    const seps = if (target == .windows) "/\\" else "/";
    const base = source[if (std.mem.findLastAny(u8, source, seps)) |i| i + 1 else 0..];
    const dot = std.mem.findScalarLast(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

const testing = std.testing;

test "each source gets its own output directory, and its program" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try outputName(a, "/p/a/main.f90", .linux);
    try testing.expect(!std.mem.eql(u8, x, try outputName(a, "/p/b/main.f90", .linux)));
    try testing.expectEqualStrings(x, try outputName(a, "/p/a/main.f90", .linux));
    try testing.expect(std.mem.startsWith(u8, x, "main-") and x.len == "main-".len + 10);
    // Windows paths that differ only in case are the same file
    try testing.expectEqualStrings(try outputName(a, "C:\\P\\main.f90", .windows), try outputName(a, "c:\\p\\main.f90", .windows));
    try testing.expectEqualStrings("hello", try programName(a, "/p/hello.F90", .linux));
    try testing.expectEqualStrings("hello.exe", try programName(a, "C:\\p\\hello.f", .windows));
}

test "the compiler's directory goes on the PATH on Windows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: Environ.Map = .init(a);
    try env.put("Path", "C:\\Windows");
    try testing.expectEqual(0, (try runtimeEnv(a, &env, .linux, "C:\\mingw64\\bin")).len);
    const added = try runtimeEnv(a, &env, .windows, "C:\\mingw64\\bin");
    try testing.expectEqualStrings("Path", added[0].name);
    try testing.expectEqualStrings("C:\\mingw64\\bin;C:\\Windows", added[0].value);
    try env.put("Path", "C:\\MinGW64\\bin\\;C:\\Windows");
    try testing.expectEqual(0, (try runtimeEnv(a, &env, .windows, "C:\\mingw64\\bin")).len);
}
