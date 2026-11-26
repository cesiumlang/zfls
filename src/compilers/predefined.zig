//! The symbols a compiler predefines, asked of it: gfortran's, from
//! `gfortran -cpp -dM -E` of an empty input (#541), and ifx's and ifort's,
//! which have no `-dM` (ifx 2026.2.0 on Linux: "ignoring unknown option
//! '-dM'"), from the `-D` options its driver gives fpp (`-###`, #656), else
//! from `-fpp -E` of a probe file that tests each name of `intel_names`
//! (#509); with OpenMP's option when `openmp`
//! (`_OPENMP`). gfortran predefines no target macros (`_WIN32`,
//! `__linux__`, `__x86_64__`: gfortran 16.1 of MSYS2). For the server
//! (server/compiler_macros.zig) and `--debug_parser` (debug.zig).

const std = @import("std");
const sysinfo = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const compilers = @import("../compilers.zig");
const tools = @import("../server/tools.zig");

const is_windows = sysinfo.target.os.tag == .windows;

pub const Macro = struct { name: []const u8, value: []const u8 };

/// Where and how to ask
pub const Ask = struct {
    io: Io,
    env: ?*const std.process.Environ.Map,
    /// where Intel's probe file is written, and its compiler runs
    work_dir: []const u8,
    /// where gfortran runs (null: zfls's own directory)
    cwd: ?[]const u8,
    openmp: bool,
    /// options that change what it predefines (`relevantArgs`)
    args: []const []const u8 = &.{},
};

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

/// Whether zfls asks compiler `id` what it predefines
pub fn asks(id: compilers.Id) bool {
    return id == .gfortran or id == .ifx or id == .ifort;
}

/// What `exe` (of compiler `id`) predefines, in `out_a`; null when it does
/// not run (or is no compiler zfls asks)
pub fn ask(a: Allocator, out_a: Allocator, id: compilers.Id, exe: []const u8, how: Ask) ?[]const Macro {
    return switch (id) {
        .gfortran => gfortranMacros(a, out_a, exe, how),
        .ifx, .ifort => intelMacros(a, out_a, exe, how),
        else => null,
    };
}

/// The options of `args` (a command's, `compiler_args`) that change what
/// compiler `id` predefines: gfortran's `-O...` (`__OPTIMIZE__`), `-m...`
/// (`-m32`, `-march=`), `-f...` (`-fopenacc`, `-ffast-math`), but not
/// `-fpreprocessed`, which leaves nothing to preprocess, nor
/// `-fintrinsic-modules-path` (gfortran 16.1). None of Intel's.
pub fn relevantArgs(a: Allocator, id: compilers.Id, args: []const []const u8) ![]const []const u8 {
    if (id != .gfortran) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (std.mem.eql(u8, x, "-fintrinsic-modules-path")) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, x, "-fintrinsic-modules-path=") or std.mem.eql(u8, x, "-fpreprocessed")) continue;
        if (std.mem.startsWith(u8, x, "-O") or (x.len > 2 and (std.mem.startsWith(u8, x, "-m") or std.mem.startsWith(u8, x, "-f")))) try out.append(a, x);
    }
    return out.items;
}

test "the options that change gfortran's predefined macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try relevantArgs(a, .gfortran, &.{ "-c", "-O2", "-I", "inc", "-fintrinsic-modules-path", "/m", "-ffast-math", "-fpreprocessed", "-march=native", "-Wall", "x.f" });
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("-O2", got[0]);
    try std.testing.expectEqualStrings("-ffast-math", got[1]);
    try std.testing.expectEqualStrings("-march=native", got[2]);
    try std.testing.expectEqual(@as(usize, 0), (try relevantArgs(a, .ifx, &.{"/O2"})).len);
}

/// gfortran's: `-dM` of its preprocessor, on an empty input
fn gfortranMacros(a: Allocator, out_a: Allocator, exe: []const u8, how: Ask) ?[]const Macro {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ exe, "-cpp", "-dM", "-E", "-x", "f95-cpp-input" }) catch return null;
    if (how.openmp) argv.append(a, "-fopenmp") catch return null;
    argv.appendSlice(a, how.args) catch return null;
    argv.append(a, "-") catch return null;
    const r = tools.run(a, how.io, .{
        .argv = argv.items,
        .cwd = how.cwd,
        // gfortran's cpp is in f951, which needs the DLLs of its bin (#528)
        .environ_map = tools.withExeDir(a, how.env, exe) catch return null,
        .input = "",
        .timeout = tools.seconds(20),
    }) catch return null;
    if (!r.term.success()) return null;
    return parseDefines(out_a, r.stdout) catch null;
}

/// Intel's: the `-D` options its driver gives fpp, else its preprocessor's
/// output of the probe file
fn intelMacros(a: Allocator, out_a: Allocator, exe: []const u8, how: Ask) ?[]const Macro {
    Io.Dir.cwd().createDirPath(how.io, how.work_dir) catch return null;
    const probe = std.Io.Dir.path.join(a, &.{ how.work_dir, "zfls_predefined.F90" }) catch return null;
    Io.Dir.cwd().writeFile(how.io, .{ .sub_path = probe, .data = probeText(a) catch return null }) catch return null;
    if (intelDriverMacros(a, out_a, exe, probe, how)) |defs| return defs;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, if (is_windows) &.{ exe, "/nologo", "/fpp", "/E" } else &.{ exe, "-fpp", "-E" }) catch return null;
    if (how.openmp) argv.append(a, if (is_windows) "/Qopenmp" else "-qopenmp") catch return null;
    argv.append(a, probe) catch return null;
    const r = tools.run(a, how.io, .{
        .argv = argv.items,
        .cwd = how.work_dir,
        .environ_map = tools.withExeDir(a, how.env, exe) catch return null,
        .timeout = tools.seconds(20),
    }) catch return null;
    if (!r.term.success()) return null;
    return parseProbe(out_a, r.stdout) catch null;
}

/// The `-D` options of the fpp command that `-###` prints (it runs
/// nothing), null when there is none
fn intelDriverMacros(a: Allocator, out_a: Allocator, exe: []const u8, probe: []const u8, how: Ask) ?[]const Macro {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, if (is_windows) &.{ exe, "/nologo", "-###", "/fpp", "/c" } else &.{ exe, "-###", "-fpp", "-c" }) catch return null;
    if (how.openmp) argv.append(a, if (is_windows) "/Qopenmp" else "-qopenmp") catch return null;
    argv.append(a, probe) catch return null;
    const r = tools.run(a, how.io, .{
        .argv = argv.items,
        .cwd = how.work_dir,
        .environ_map = tools.withExeDir(a, how.env, exe) catch return null,
        .timeout = tools.seconds(20),
    }) catch return null;
    const defs = (parseDriver(out_a, r.stderr) catch return null) orelse (parseDriver(out_a, r.stdout) catch return null) orelse return null;
    return if (defs.len > 0) defs else null;
}

/// The `-DNAME=VALUE` (`-DNAME`: 1) of the line of `-###` output that runs
/// fpp: `"<bin>/fpp"    "-D__INTEL_LLVM_COMPILER=20260200" ... "-I." ...`
fn parseDriver(a: Allocator, output: []const u8) !?[]const Macro {
    var it = compilers.lines(output);
    while (it.next()) |raw| {
        var parts = std.mem.splitScalar(u8, compilers.trimCr(raw), '"');
        _ = parts.next() orelse continue;
        const cmd = parts.next() orelse continue;
        var base = cmd[if (std.mem.findLastAny(u8, cmd, "/\\")) |i| i + 1 else 0..];
        if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
        if (!std.mem.eql(u8, base, "fpp")) continue;
        var out: std.ArrayList(Macro) = .empty;
        // the quoted arguments are every other part
        var quoted = false;
        while (parts.next()) |p| : (quoted = !quoted) {
            if (!quoted or !std.mem.startsWith(u8, p, "-D") or p.len == 2) continue;
            const def = p[2..];
            const eq = std.mem.findScalar(u8, def, '=');
            try out.append(a, .{ .name = try a.dupe(u8, def[0 .. eq orelse def.len]), .value = if (eq) |e| try a.dupe(u8, def[e + 1 ..]) else "1" });
        }
        return out.items;
    }
    return null;
}

/// The `#define NAME VALUE` lines of `-dM` output (object-like macros only)
fn parseDefines(a: Allocator, output: []const u8) ![]const Macro {
    var out: std.ArrayList(Macro) = .empty;
    var it = compilers.lines(output);
    while (it.next()) |raw| {
        const line = compilers.trimCr(raw);
        if (!std.mem.startsWith(u8, line, "#define ")) continue;
        const rest = line["#define ".len..];
        const end = std.mem.findAny(u8, rest, " (") orelse rest.len;
        if (end == 0 or (end < rest.len and rest[end] == '(')) continue;
        const value = if (end < rest.len) std.mem.trim(u8, rest[end + 1 ..], " \t") else "";
        try out.append(a, .{ .name = try a.dupe(u8, rest[0..end]), .value = try a.dupe(u8, value) });
    }
    return out.items;
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

test "ifx's predefined symbols, from the fpp command of -###" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // conda-forge's ifx 2026.2.0 on Linux x64 (CI), `-### -fpp -qopenmp -c`
    const linux = "\"/home/runner/work/_temp/ifx/bin/fpp\"    \"-D__INTEL_LLVM_COMPILER=20260200\" \"-D__INTEL_LLVM_COMPILER_UPDATE=0\" " ++
        "\"-D__INTEL_COMPILER=20260200\" \"-D__INTEL_COMPILER_UPDATE=0\" \"-D__unix__\" \"-D__unix\" \"-D__linux__\" \"-D__linux\" " ++
        "\"-D__gnu_linux__\" \"-Dunix\" \"-Dlinux\" \"-D__ELF__\" \"-D__x86_64\" \"-D__x86_64__\" \"-D__amd64\" \"-D__amd64__\" " ++
        "\"-D__INTEL_COMPILER_BUILD_DATE=20261001\" \"-D_OPENMP=202011\" \"-D__MMX__\" \"-D__SSE__\" \"-D__SSE_MATH__\" \"-D__SSE2__\" " ++
        "\"-D__SSE2_MATH__\" \"-D__pentium4\" \"-D__pentium4__\" \"-D__tune_pentium4__\" \"-I.\" \"-I/usr/include\" \"-4Ycpp\" \"x.F90\"\n" ++
        "\"/home/runner/work/_temp/ifx/bin/compiler/xfortcom\"    \"-triple\" \"x86_64-unknown-linux-gnu\" \"-D__WRONG\"\n";
    const l = (try parseDriver(a, linux)).?;
    try std.testing.expectEqual(@as(usize, 26), l.len);
    try std.testing.expectEqualStrings("__INTEL_LLVM_COMPILER_UPDATE", l[1].name);
    try std.testing.expectEqualStrings("0", l[1].value);
    try std.testing.expectEqualStrings("__unix__", l[4].name);
    try std.testing.expectEqualStrings("1", l[4].value);
    try std.testing.expectEqualStrings("_OPENMP", l[17].name);
    try std.testing.expectEqualStrings("202011", l[17].value);
    for (l) |d| try std.testing.expect(!std.mem.eql(u8, d.name, "_WIN32"));
    // ifx 2026.2.0 on Windows, `-### /fpp /c` (an excerpt)
    const win = "\"C:\\ifx\\Library\\bin\\fpp\"    \"-D__INTEL_LLVM_COMPILER=20260200\" \"-D_WIN32\" \"-D_M_X64=100\" \"-D_MSC_FULL_VER=150011209\" \"-D_MSC_EXTENSIONS\" \"-D_MT\" \"-I.\" \"ops.F90\"\r\n";
    const w = (try parseDriver(a, win)).?;
    try std.testing.expectEqual(@as(usize, 6), w.len);
    try std.testing.expectEqualStrings("_M_X64", w[2].name);
    try std.testing.expectEqualStrings("100", w[2].value);
    try std.testing.expect((try parseDriver(a, "ifx: command line warning #10006: ignoring unknown option '-dM'\n")) == null);
}

test "gfortran's predefined macros, from -dM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // MSYS2's gfortran 16.1, -fopenmp (an excerpt), and a function-like and an empty macro
    const defs = try parseDefines(a, "# 1 \"<stdin>\"\r\n#define _LANGUAGE_FORTRAN 1\r\n#define __BYTE_ORDER__ __ORDER_LITTLE_ENDIAN__\r\n" ++
        "#define __GFORTRAN__ 1\r\n#define __GNUC__ 16\r\n#define __VERSION__ \"16.1.0\"\r\n#define _OPENMP 202111\r\n#define F(x) x\r\n#define EMPTY\r\n");
    try std.testing.expectEqual(@as(usize, 7), defs.len);
    try std.testing.expectEqualStrings("__ORDER_LITTLE_ENDIAN__", defs[1].value);
    try std.testing.expectEqualStrings("__GNUC__", defs[3].name);
    try std.testing.expectEqualStrings("16", defs[3].value);
    try std.testing.expectEqualStrings("\"16.1.0\"", defs[4].value);
    try std.testing.expectEqualStrings("202111", defs[5].value);
    try std.testing.expectEqualStrings("EMPTY", defs[6].name);
    try std.testing.expectEqualStrings("", defs[6].value);
}
