//! `zfls lfortran-ir`: an LFortran program built through its LLVM IR, with
//! the debug information LFortran's own build leaves out: the lines of
//! PRINT and WRITE statements (#991, lfortran_lines.zig) and the variables'
//! types (#366, lfortran_types.zig). LFortran writes the program's IR with
//! its debug metadata (`-g --show-llvm`); zfls patches it, clang (or llc)
//! compiles it. On Windows (#176), where LFortran writes DWARF only and
//! refuses `-g`, the IR is marked for CodeView and lld-link links it with
//! LFortran's runtime and writes the PDB, which Windows's Debugger Engine
//! reads; elsewhere (#992) it is marked for DWARF and LFortran links it
//! (on macOS, dsymutil then writes the `.dSYM`).
//! Its calls of `print_stacktrace_addresses` are left out: LFortran 0.69's
//! traceback needs the files of its own `-g` link, and without them ends
//! the program at ERROR STOP before its message (on macOS, #470, aborts it).
//!
//!     zfls lfortran-ir --lfortran EXE (--clang EXE | --llc EXE)
//!         [--lld-link EXE --runtime LIB] -o PROGRAM [LFORTRAN OPTIONS...] SOURCE
//!
//! lld-link takes the libraries of `LIB` and the options of `LINK` (the ifx
//! kit's, run/kit.zig), which the build's environment has.

const std = @import("std");
const sysinfo = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const stdio = @import("../stdio.zig");
const paths = @import("../paths.zig");
const lfortran_lines = @import("lfortran_lines.zig");
const lfortran_types = @import("lfortran_types.zig");

/// The IR for x86-64 Windows, MSVC's ABI
pub const triple = "x86_64-pc-windows-msvc";

/// The debug information the IR is marked for
pub const Format = enum { codeview, dwarf };

/// LFortran's IR (`--show-llvm`) marked for `format`: the module flags
/// without which LLVM drops the debug information (LFortran writes none),
/// for CodeView a target triple, and the source files' directory `dir`
/// (absolute, with `/`) for its `directory: "."`. Null when the IR has
/// module flags already: it is not LFortran's as zfls knows it.
pub fn patch(a: Allocator, ir: []const u8, dir: []const u8, format: Format) !?[]const u8 {
    if (std.mem.find(u8, ir, "!llvm.module.flags") != null) return null;
    var out: std.ArrayList(u8) = .empty;
    var max_id: u64 = 0;
    var has_triple = format != .codeview;
    var it = std.mem.splitScalar(u8, ir, '\n');
    while (it.next()) |line_in| {
        const line = std.mem.trimEnd(u8, line_in, "\r");
        if (std.mem.startsWith(u8, line, "target triple")) has_triple = true;
        if (line.len > 1 and line[0] == '!' and std.ascii.isDigit(line[1])) {
            var e: usize = 1;
            while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
            max_id = @max(max_id, std.fmt.parseInt(u64, line[1..e], 10) catch 0);
        }
        try out.appendSlice(a, try std.mem.replaceOwned(u8, a, line, "directory: \".\"", try a.print("directory: \"{s}\"", .{dir})));
        try out.append(a, '\n');
        if (std.mem.startsWith(u8, line, "source_filename") and !has_triple) {
            try out.print(a, "target triple = \"{s}\"\n", .{triple});
            has_triple = true;
        }
    }
    const flag = switch (format) {
        .codeview => "i32 2, !\"CodeView\", i32 1",
        .dwarf => "i32 7, !\"Dwarf Version\", i32 4",
    };
    try out.print(a, "!llvm.module.flags = !{{!{d}, !{d}}}\n!{d} = !{{{s}}}\n!{d} = !{{i32 2, !\"Debug Info Version\", i32 3}}\n", .{ max_id + 1, max_id + 2, max_id + 1, flag, max_id + 2 });
    return out.items;
}

/// The IR without its calls of LFortran's traceback (`-g`'s, before an
/// ERROR STOP's message), which end the program there in a build of
/// zfls's (on macOS "The stack address was not found", LFortran 0.69, #470)
pub fn withoutTraceback(a: Allocator, ir: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, ir, '\n');
    var first = true;
    while (it.next()) |line| {
        const code = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, code, "call ") and std.mem.find(u8, code, "@print_stacktrace_addresses(") != null) continue;
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, line);
    }
    return out.items;
}

const Options = struct {
    lfortran: []const u8,
    clang: []const u8,
    llc: []const u8,
    lld_link: []const u8,
    runtime: []const u8,
    program: []const u8,
    /// LFortran's options, the source last
    rest: []const []const u8,
};

fn options(args: []const []const u8) ?Options {
    var o: Options = .{ .lfortran = "", .clang = "", .llc = "", .lld_link = "", .runtime = "", .program = "", .rest = &.{} };
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        const v = args[i + 1];
        const field: *[]const u8 = if (std.mem.eql(u8, args[i], "--lfortran"))
            &o.lfortran
        else if (std.mem.eql(u8, args[i], "--clang"))
            &o.clang
        else if (std.mem.eql(u8, args[i], "--llc"))
            &o.llc
        else if (std.mem.eql(u8, args[i], "--lld-link"))
            &o.lld_link
        else if (std.mem.eql(u8, args[i], "--runtime"))
            &o.runtime
        else if (std.mem.eql(u8, args[i], "-o"))
            &o.program
        else
            break;
        field.* = v;
    }
    o.rest = args[i..];
    if (o.lfortran.len == 0 or (o.clang.len == 0) == (o.llc.len == 0) or (o.lld_link.len == 0) != (o.runtime.len == 0) or o.program.len == 0 or o.rest.len == 0) return null;
    return o;
}

fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.mem.print(&buf, fmt, args) catch return;
    stdio.stderr().writeStreamingAll(io, text) catch {};
}

/// Runs `argv`; its output passed on, and whether it succeeded
fn step(a: Allocator, io: Io, environ: *const std.process.Environ.Map, argv: []const []const u8, stdout: ?*[]u8) !bool {
    const r = std.process.run(a, io, .{ .argv = argv, .environ_map = environ }) catch |e| {
        say(io, "zfls lfortran-ir: {s} did not start: {s}\n", .{ argv[0], @errorName(e) });
        return false;
    };
    if (r.stderr.len > 0) stdio.stderr().writeStreamingAll(io, r.stderr) catch {};
    if (stdout) |o| o.* = r.stdout else if (r.stdout.len > 0) stdio.stdout().writeStreamingAll(io, r.stdout) catch {};
    return switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// The command that compiles `ll` into `obj`: clang's or llc's, position
/// independent on Linux (whose linkers make PIE programs by default)
fn compileArgs(a: Allocator, o: Options, ll: []const u8, obj: []const u8) ![]const []const u8 {
    const linux = sysinfo.target.os.tag == .linux;
    if (o.clang.len > 0) {
        const target: []const []const u8 = if (o.lld_link.len > 0) &.{"--target=" ++ triple} else if (linux) &.{"-fPIC"} else &.{};
        return std.mem.concat(a, []const u8, &.{ &.{ o.clang, "-c", "-g", "-O0", "-Wno-override-module" }, target, &.{ ll, "-o", obj } });
    }
    const target: []const []const u8 = if (o.lld_link.len > 0) &.{"-mtriple=" ++ triple} else if (linux) &.{"--relocation-model=pic"} else &.{};
    return std.mem.concat(a, []const u8, &.{ &.{ o.llc, "-O0", "-filetype=obj" }, target, &.{ ll, "-o", obj } });
}

/// The subcommand, with the arguments after its name: 0 when the program
/// is built, 1 when a step failed (its output said why), 2 for a usage error
pub fn main(a: Allocator, io: Io, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    const o = options(args) orelse {
        say(io, "usage: zfls lfortran-ir --lfortran EXE (--clang EXE | --llc EXE) [--lld-link EXE --runtime LIB] -o PROGRAM [OPTIONS...] SOURCE\n", .{});
        return 2;
    };
    const format: Format = if (o.lld_link.len > 0) .codeview else .dwarf;
    // 1. LFortran's IR, with its debug metadata
    var ir: []u8 = &.{};
    const show = try std.mem.concat(a, []const u8, &.{ &.{ o.lfortran, "-g", "--show-llvm" }, o.rest });
    if (!try step(a, io, environ, show, &ir)) return 1;
    // 2. the lines of its PRINT and WRITE statements (#991) and the types of
    // its variables (#366), marked for the debug information, with the
    // sources' absolute directory
    const source = o.rest[o.rest.len - 1];
    const lined = if (Io.Dir.cwd().readFileAlloc(io, source, a, .limited(1 << 26))) |text| blk: {
        const parsed = try lfortran_lines.parse(a, io, source, text);
        const procs = try lfortran_lines.ofParsed(a, parsed.file, parsed.ast);
        break :blk try lfortran_types.patch(a, try lfortran_lines.patch(a, ir, procs), try lfortran_types.ofAst(a, parsed.ast, procs));
    } else |_| ir;
    const cwd = try a.dupe(u8, paths.getCwd());
    std.mem.replaceScalar(u8, cwd, '\\', '/');
    const traced = try withoutTraceback(a, lined);
    const patched = (try patch(a, traced, cwd, format)) orelse {
        say(io, "zfls lfortran-ir: {s}'s IR has module flags already; zfls does not know it\n", .{o.lfortran});
        return 1;
    };
    const stem = if (std.mem.endsWith(u8, o.program, ".exe")) o.program[0 .. o.program.len - 4] else o.program;
    const ll = try a.print("{s}.ll", .{stem});
    const obj = try a.print("{s}.{s}", .{ stem, if (format == .codeview) "obj" else "o" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ll, .data = patched });
    // 3. compiled, 4. linked: by lld-link, with the PDB, or by LFortran
    if (!try step(a, io, environ, try compileArgs(a, o, ll, obj), null)) return 1;
    const link: []const []const u8 = if (format == .codeview)
        &.{ o.lld_link, "/NOLOGO", "/DEBUG", try a.print("/OUT:{s}", .{o.program}), obj, o.runtime }
    else
        &.{ o.lfortran, obj, "-o", o.program };
    if (!try step(a, io, environ, link, null)) return 1;
    // 5. on macOS the debug information gathered into PROGRAM.dSYM, which
    // gdb reads (lldb reads the object file too), by the dsymutil next to
    // LFortran (conda-forge's) or Xcode's
    if (sysinfo.target.os.tag == .macos) {
        const beside = try Io.Dir.path.join(a, &.{ paths.dirname(o.lfortran), "dsymutil" });
        const dsymutil = if (paths.isFile(io, beside)) beside else "dsymutil";
        if (!try step(a, io, environ, &.{ dsymutil, o.program }, null)) return 1;
    }
    return 0;
}

const testing = std.testing;

test "LFortran's IR marked for CodeView (#176) and DWARF (#992)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ir =
        \\; ModuleID = 'LFortran'
        \\source_filename = "LFortran"
        \\target datalayout = "e-m:w"
        \\
        \\!llvm.dbg.cu = !{!0}
        \\!0 = distinct !DICompileUnit(language: DW_LANG_C, file: !1)
        \\!1 = !DIFile(filename: "t.f90", directory: ".")
        \\!17 = !DILocation(line: 9, column: 3, scope: !2)
        \\
    ;
    const out = (try patch(a, ir, "C:/work", .codeview)).?;
    try testing.expect(std.mem.find(u8, out, "source_filename = \"LFortran\"\ntarget triple = \"x86_64-pc-windows-msvc\"\n") != null);
    try testing.expect(std.mem.find(u8, out, "directory: \"C:/work\"") != null);
    try testing.expect(std.mem.find(u8, out, "!llvm.module.flags = !{!18, !19}\n!18 = !{i32 2, !\"CodeView\", i32 1}\n!19 = !{i32 2, !\"Debug Info Version\", i32 3}\n") != null);
    try testing.expectEqual(null, try patch(a, "!llvm.module.flags = !{!0}\n", "C:/work", .codeview));
    const dwarf = (try patch(a, ir, "/work", .dwarf)).?;
    try testing.expect(std.mem.find(u8, dwarf, "target triple") == null);
    try testing.expect(std.mem.find(u8, dwarf, "directory: \"/work\"") != null);
    try testing.expect(std.mem.find(u8, dwarf, "!18 = !{i32 7, !\"Dwarf Version\", i32 4}\n") != null);
}

test "LFortran's traceback left out (#470)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ir = "then:\n  call void (ptr, i1, ...) @print_stacktrace_addresses(ptr @3, i1 true), !dbg !9\n  call void @exit(i32 3)\ndeclare void @print_stacktrace_addresses(ptr, i1, ...)\n";
    try testing.expectEqualStrings("then:\n  call void @exit(i32 3)\ndeclare void @print_stacktrace_addresses(ptr, i1, ...)\n", try withoutTraceback(a, ir));
}

test "the subcommand's options (#176, #992)" {
    const o = options(&.{ "--lfortran", "lf", "--clang", "c", "--lld-link", "l", "--runtime", "r.lib", "-o", "p.exe", "-I", "inc", "t.f90" }).?;
    try testing.expectEqualStrings("p.exe", o.program);
    try testing.expectEqual(3, o.rest.len);
    const d = options(&.{ "--lfortran", "lf", "--llc", "llc", "-o", "p", "t.f90" }).?;
    try testing.expectEqualStrings("llc", d.llc);
    try testing.expectEqual(null, options(&.{ "--lfortran", "lf", "t.f90" }));
    // one compiler of the IR, and lld-link with the runtime or neither
    try testing.expectEqual(null, options(&.{ "--lfortran", "lf", "--clang", "c", "--llc", "l", "-o", "p", "t.f90" }));
    try testing.expectEqual(null, options(&.{ "--lfortran", "lf", "--clang", "c", "--lld-link", "l", "-o", "p", "t.f90" }));
}
