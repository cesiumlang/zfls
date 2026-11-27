//! `zfls lfortran-codeview`: an LFortran program built with CodeView debug
//! information on Windows (#176), which LFortran's own build cannot make
//! (it writes DWARF, and refuses `-g` there). LFortran writes the program's
//! LLVM IR with its debug metadata (`-g --show-llvm`); zfls marks it for
//! CodeView, clang compiles it, and lld-link links it with LFortran's
//! runtime and writes the PDB, which Windows's Debugger Engine reads.
//!
//!     zfls lfortran-codeview --lfortran EXE --clang EXE --lld-link EXE
//!         --runtime LIB -o PROGRAM [LFORTRAN OPTIONS...] SOURCE
//!
//! lld-link takes the libraries of `LIB` and the options of `LINK` (the ifx
//! kit's, run/kit.zig), which the build's environment has.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const stdio = @import("../stdio.zig");
const paths = @import("../paths.zig");
const lfortran_lines = @import("lfortran_lines.zig");
const lfortran_types = @import("lfortran_types.zig");

/// The IR for x86-64 Windows, MSVC's ABI
pub const triple = "x86_64-pc-windows-msvc";

/// LFortran's IR (`--show-llvm`) made for CodeView: a target triple, the
/// module flags without which LLVM drops the debug information (LFortran
/// writes none), and the source files' directory `dir` (absolute, with `/`)
/// for its `directory: "."`. Null when the IR has module flags already: it
/// is not LFortran's as zfls knows it.
pub fn patch(a: Allocator, ir: []const u8, dir: []const u8) !?[]const u8 {
    if (std.mem.find(u8, ir, "!llvm.module.flags") != null) return null;
    var out: std.ArrayList(u8) = .empty;
    var max_id: u64 = 0;
    var has_triple = false;
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
    try out.print(a, "!llvm.module.flags = !{{!{d}, !{d}}}\n!{d} = !{{i32 2, !\"CodeView\", i32 1}}\n!{d} = !{{i32 2, !\"Debug Info Version\", i32 3}}\n", .{ max_id + 1, max_id + 2, max_id + 1, max_id + 2 });
    return out.items;
}

const Options = struct {
    lfortran: []const u8,
    clang: []const u8,
    lld_link: []const u8,
    runtime: []const u8,
    program: []const u8,
    /// LFortran's options, the source last
    rest: []const []const u8,
};

fn options(args: []const []const u8) ?Options {
    var o: Options = .{ .lfortran = "", .clang = "", .lld_link = "", .runtime = "", .program = "", .rest = &.{} };
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        const v = args[i + 1];
        if (std.mem.eql(u8, args[i], "--lfortran")) o.lfortran = v else if (std.mem.eql(u8, args[i], "--clang")) o.clang = v else if (std.mem.eql(u8, args[i], "--lld-link")) o.lld_link = v else if (std.mem.eql(u8, args[i], "--runtime")) o.runtime = v else if (std.mem.eql(u8, args[i], "-o")) o.program = v else break;
    }
    o.rest = args[i..];
    if (o.lfortran.len == 0 or o.clang.len == 0 or o.lld_link.len == 0 or o.runtime.len == 0 or o.program.len == 0 or o.rest.len == 0) return null;
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
        say(io, "zfls lfortran-codeview: {s} did not start: {s}\n", .{ argv[0], @errorName(e) });
        return false;
    };
    if (r.stderr.len > 0) stdio.stderr().writeStreamingAll(io, r.stderr) catch {};
    if (stdout) |o| o.* = r.stdout else if (r.stdout.len > 0) stdio.stdout().writeStreamingAll(io, r.stdout) catch {};
    return switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// The subcommand, with the arguments after its name: 0 when the program
/// is built, 1 when a step failed (its output said why), 2 for a usage error
pub fn main(a: Allocator, io: Io, environ: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    const o = options(args) orelse {
        say(io, "usage: zfls lfortran-codeview --lfortran EXE --clang EXE --lld-link EXE --runtime LIB -o PROGRAM [OPTIONS...] SOURCE\n", .{});
        return 2;
    };
    // 1. LFortran's IR, with its debug metadata
    var ir: []u8 = &.{};
    const show = try std.mem.concat(a, []const u8, &.{ &.{ o.lfortran, "-g", "--show-llvm" }, o.rest });
    if (!try step(a, io, environ, show, &ir)) return 1;
    // 2. the lines of its PRINT and WRITE statements (#470) and the types of
    // its variables (#366), marked for CodeView, with the sources' absolute
    // directory
    const source = o.rest[o.rest.len - 1];
    const lined = if (Io.Dir.cwd().readFileAlloc(io, source, a, .limited(1 << 26))) |text| blk: {
        const parsed = try lfortran_lines.parse(a, io, source, text);
        const procs = try lfortran_lines.ofParsed(a, parsed.file, parsed.ast);
        break :blk try lfortran_types.patch(a, try lfortran_lines.patch(a, ir, procs), try lfortran_types.ofAst(a, parsed.ast, procs));
    } else |_| ir;
    const cwd = try a.dupe(u8, paths.getCwd());
    std.mem.replaceScalar(u8, cwd, '\\', '/');
    const patched = (try patch(a, lined, cwd)) orelse {
        say(io, "zfls lfortran-codeview: {s}'s IR has module flags already; zfls does not know it\n", .{o.lfortran});
        return 1;
    };
    const stem = if (std.mem.endsWith(u8, o.program, ".exe")) o.program[0 .. o.program.len - 4] else o.program;
    const ll = try a.print("{s}.ll", .{stem});
    const obj = try a.print("{s}.obj", .{stem});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ll, .data = patched });
    // 3. compiled by clang, 4. linked by lld-link, with the PDB
    if (!try step(a, io, environ, &.{ o.clang, "-c", "-g", "-O0", "--target=" ++ triple, "-Wno-override-module", ll, "-o", obj }, null)) return 1;
    const out_arg = try a.print("/OUT:{s}", .{o.program});
    if (!try step(a, io, environ, &.{ o.lld_link, "/NOLOGO", "/DEBUG", out_arg, obj, o.runtime }, null)) return 1;
    return 0;
}

const testing = std.testing;

test "LFortran's IR marked for CodeView (#176)" {
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
    const out = (try patch(a, ir, "C:/work")).?;
    try testing.expect(std.mem.find(u8, out, "source_filename = \"LFortran\"\ntarget triple = \"x86_64-pc-windows-msvc\"\n") != null);
    try testing.expect(std.mem.find(u8, out, "directory: \"C:/work\"") != null);
    try testing.expect(std.mem.find(u8, out, "!llvm.module.flags = !{!18, !19}\n!18 = !{i32 2, !\"CodeView\", i32 1}\n!19 = !{i32 2, !\"Debug Info Version\", i32 3}\n") != null);
    try testing.expectEqual(null, try patch(a, "!llvm.module.flags = !{!0}\n", "C:/work"));
}

test "the subcommand's options (#176)" {
    const o = options(&.{ "--lfortran", "lf", "--clang", "c", "--lld-link", "l", "--runtime", "r.lib", "-o", "p.exe", "-I", "inc", "t.f90" }).?;
    try testing.expectEqualStrings("p.exe", o.program);
    try testing.expectEqual(3, o.rest.len);
    try testing.expectEqual(null, options(&.{ "--lfortran", "lf", "t.f90" }));
}
