//! `zfls/buildCommand`: how to build a Fortran file into a program to run
//! or debug, for every editor (zfls #577). The compilers are stand-ins
//! (empty files): the request finds them, it does not run them;
//! tests/build_command.zig builds with real ones.

const std = @import("std");
const sysinfo = @import("builtin");
const h = @import("harness.zig");

const windows = sysinfo.target.os.tag == .windows;
const exe = if (windows) ".exe" else "";

fn init() !*h.Workspace {
    return h.Workspace.init(&.{
        .{ .name = "src/hello.f90", .text = "program hello\nend program hello\n" },
        .{ .name = "tools/gfortran-14" ++ exe, .text = "" },
        .{ .name = "tools/ifx" ++ exe, .text = "" },
    }, .{});
}

fn args(v: h.json.Value) []h.json.Value {
    return h.json.items(h.json.get(v, "args"));
}

/// A file of the workspace, as zfls writes paths
fn native(w: *h.Workspace, name: []const u8) ![]const u8 {
    return h.zfls.paths.normpath(w.a(), try w.path(name));
}

fn str(v: h.json.Value, key: []const u8) []const u8 {
    return h.json.str(h.json.get(v, key)) orelse "";
}

test "zfls/buildCommand: the compiler, its arguments, the output directory and the program" {
    const w = try init();
    defer w.deinit();
    const v = try w.zflsRequest("zfls/buildCommand", .{
        .textDocument = .{ .uri = try w.uri("src/hello.f90") },
        .compiler = "gfortran",
        .compilerPath = "tools/gfortran-14" ++ exe,
        .outputDirectory = "build/run",
    });
    try std.testing.expectEqualStrings(try native(w, "tools/gfortran-14" ++ exe), str(v, "compiler"));
    try std.testing.expectEqualStrings("gfortran", str(v, "name"));
    try std.testing.expectEqualStrings("dwarf", str(v, "debugInfo"));
    try std.testing.expectEqualStrings(if (sysinfo.target.os.tag == .macos) "lldb" else "gdb", str(v, "debugger"));
    const out = try native(w, "build/run");
    try std.testing.expectEqualStrings(out, str(v, "cwd"));
    const program = try std.Io.Dir.path.join(w.a(), &.{ out, "hello" ++ exe });
    try std.testing.expectEqualStrings(program, str(v, "program"));
    // created, for the compiler to write into
    try std.testing.expect(h.zfls.paths.isDir(std.testing.io, out));
    const a = args(v);
    try std.testing.expectEqualStrings("-g", a[0].string);
    try std.testing.expectEqualStrings(try native(w, "src/hello.f90"), a[a.len - 1].string);
    try std.testing.expectEqualStrings(program, a[a.len - 2].string);
    try std.testing.expectEqualStrings("-o", a[a.len - 3].string);
    try std.testing.expectEqualStrings(try std.mem.concat(w.a(), u8, &.{ "-I", try native(w, "src") }), a[a.len - 4].string);
}

test "zfls/buildCommand: the user's options in place of the defaults" {
    const w = try init();
    defer w.deinit();
    const v = try w.zflsRequest("zfls/buildCommand", .{
        .textDocument = .{ .uri = try w.uri("src/hello.f90") },
        .compilerPath = "tools/gfortran-14" ++ exe,
        .args = &[_][]const u8{ "-O2", "-fcheck=all" },
        .outputDirectory = "out",
    });
    const a = args(v);
    try std.testing.expectEqual(@as(usize, 6), a.len);
    try std.testing.expectEqualStrings("-O2", a[0].string);
    try std.testing.expectEqualStrings("-fcheck=all", a[1].string);
}

test "zfls/buildCommand: Intel's options on Windows, and Windows's Debugger Engine for its PDB" {
    if (!windows) return error.SkipZigTest;
    const w = try init();
    defer w.deinit();
    const v = try w.zflsRequest("zfls/buildCommand", .{
        .textDocument = .{ .uri = try w.uri("src/hello.f90") },
        .compiler = "ifx",
        .compilerPath = "tools",
        .outputDirectory = "out",
    });
    try std.testing.expectEqualStrings("ifx", str(v, "name"));
    try std.testing.expectEqualStrings("pdb", str(v, "debugInfo"));
    try std.testing.expectEqualStrings("dbgeng", str(v, "debugger"));
    const a = args(v);
    try std.testing.expectEqualStrings("/nologo", a[0].string);
    try std.testing.expectEqualStrings("/Zi", a[1].string);
    try std.testing.expect(std.mem.startsWith(u8, a[a.len - 2].string, "/exe:"));
    // the compiler's runtime libraries on the PATH
    try std.testing.expect(h.json.get(v, "runEnv").?.object.count() == 1);
}

test "zfls/buildCommand: without a file, only the compiler's part; null without the compiler" {
    const w = try init();
    defer w.deinit();
    const v = try w.zflsRequest("zfls/buildCommand", .{ .compilerPath = "tools/gfortran-14" ++ exe });
    try std.testing.expectEqualStrings("gfortran", str(v, "name"));
    try std.testing.expect(h.json.get(v, "args") == null and h.json.get(v, "program") == null);
    const none = try w.zflsRequest("zfls/buildCommand", .{
        .textDocument = .{ .uri = try w.uri("src/hello.f90") },
        .compiler = "nagfor",
        .compilerPath = "tools",
    });
    try std.testing.expect(none == .null);
}

test "zfls/buildCommand: on Windows a compiler given by its path has its directory on the build's PATH too (#543)" {
    if (!windows) return error.SkipZigTest;
    const w = try init();
    defer w.deinit();
    const v = try w.zflsRequest("zfls/buildCommand", .{
        .textDocument = .{ .uri = try w.uri("src/hello.f90") },
        .compilerPath = "tools/gfortran-14" ++ exe,
        .outputDirectory = "out",
    });
    const tools = try native(w, "tools");
    for ([_][]const u8{ "env", "runEnv" }) |key| {
        var it = h.json.get(v, key).?.object.iterator();
        const path = while (it.next()) |e| {
            if (std.ascii.eqlIgnoreCase(e.key_ptr.*, "PATH")) break e.value_ptr.string;
        } else return error.TestExpectedEqual;
        try std.testing.expect(std.ascii.startsWithIgnoreCase(path, tools));
    }
}

test "zfls/buildCommand: conda-forge's ifx on Windows finds its modules and links with its lld-link and the ifx kit (#510)" {
    if (!windows) return error.SkipZigTest;
    const w = try h.Workspace.init(&.{
        .{ .name = "src/hello.f90", .text = "program hello\nuse iso_fortran_env\nend program hello\n" },
        .{ .name = "env/Library/bin/ifx.exe", .text = "" },
        .{ .name = "env/Library/bin/ifx.cfg", .text = "" },
        .{ .name = "env/Library/bin/compiler/lld-link.exe", .text = "" },
        .{ .name = "env/opt/compiler/include/intel64/iso_fortran_env.modintr", .text = "" },
    }, .{});
    defer w.deinit();
    const v = try w.zflsRequest("zfls/buildCommand", .{
        .textDocument = .{ .uri = try w.uri("src/hello.f90") },
        .compiler = "ifx",
        .compilerPath = "env/Library/bin",
        .outputDirectory = "out",
    });
    const modules = try std.mem.concat(w.a(), u8, &.{ "/I", try native(w, "env/opt/compiler/include/intel64") });
    var has_modules = false;
    var has_lld = false;
    for (args(v)) |x| {
        if (std.mem.eql(u8, x.string, modules)) has_modules = true;
        if (std.mem.eql(u8, x.string, "/fuse-ld=lld")) has_lld = true;
    }
    try std.testing.expect(has_modules);
    // with the kit next to zfls, its lld-link; without it, a note says so
    if (!has_lld) try std.testing.expect(std.mem.find(u8, str(v, "note"), "no ifx kit") != null);
}
