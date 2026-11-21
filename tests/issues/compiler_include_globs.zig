//! The compiler check's include directories (`compiler_include_dirs`, the
//! VS Code extension's `zfls.linter.includePaths`): glob patterns expanded
//! by zfls, relative to the workspace, as `source_dirs` are, so that every
//! editor can give them (zfls #580). The cases of the extension's unit
//! test of its own expansion, which this replaces.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;
const io = std.testing.io;

/// A stand-in gfortran whose message is its command line
const echo: h.File = if (is_windows)
    .{ .name = "gfortran.cmd", .text = "@echo off\r\necho a.f90:1:1: Error: args %* 1>&2\r\nexit /b 1\r\n" }
else
    .{ .name = "gfortran.sh", .text = "#!/bin/sh\necho \"a.f90:1:1: Error: args $*\" >&2\nexit 1\n" };

/// The `-I` directories the compiler was given, relative to the workspace,
/// with `/`
fn includes(w: *h.Workspace) ![]const []const u8 {
    if (!is_windows) try w.tmp.dir.setFilePermissions(io, echo.name, .executable_file, .{});
    try w.open("a.f90", "fortran");
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", "args ", 60)) orelse return error.NoCompilerDiagnostics;
    const at = std.mem.find(u8, sent, "args ").?;
    // the message's end: a quote of the JSON, not an escaped one
    const end = std.mem.findPos(u8, sent, at, "\",\"") orelse sent.len;
    var out: std.ArrayList([]const u8) = .empty;
    const root = try h.zfls.paths.realpath(io, w.a(), w.root);
    var it = std.mem.tokenizeScalar(u8, sent[at + 5 .. end], ' ');
    while (it.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "-I")) continue;
        // JSON: `\\` is one backslash
        const dir = try std.mem.replaceOwned(u8, w.a(), arg[2..], "\\\\", "/");
        const base = try std.mem.replaceOwned(u8, w.a(), root, "\\", "/");
        if (std.mem.startsWith(u8, dir, base) and dir.len > base.len) try out.append(w.a(), dir[base.len + 1 ..]);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

const files = [_]h.File{
    .{ .name = "a.f90", .text = "program a\nend program a\n" },
    .{ .name = "build/a/include/.keep", .text = "" },
    .{ .name = "build/b/include/.keep", .text = "" },
    .{ .name = "build/b/src/.keep", .text = "" },
    .{ .name = "other/include/.keep", .text = "" },
    // a file: no include directory, whatever matches it
    .{ .name = "build/file.txt", .text = "" },
    echo,
};

fn check(comptime dirs: []const u8, expected: []const []const u8) !void {
    const opts = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ echo.name ++ "\", \"compiler_no_dependencies\": true, \"compiler_include_dirs\": " ++ dirs ++ "}";
    const w = try h.Workspace.init(&files, .{ .init_options = opts });
    defer w.deinit();
    const got = try includes(w);
    try h.expect(got.len == expected.len, "{d} include directories, not {d}: {any}", .{ got.len, expected.len, got });
    for (expected, got) |e, g| try h.expect(std.mem.eql(u8, e, g), "{s}, not {s}", .{ e, g });
}

test "#580 compiler_include_dirs: a glob pattern matches directories" {
    try check("[\"build/*/include\"]", &.{ "build/a/include", "build/b/include" });
}

test "#580 compiler_include_dirs: ** matches any depth" {
    try check("[\"**/include\"]", &.{ "build/a/include", "build/b/include", "other/include" });
}

test "#580 compiler_include_dirs: only directories, and a character class" {
    try check("[\"build/*\"]", &.{ "build/a", "build/b" });
    try check("[\"build/[a]/*\"]", &.{"build/a/include"});
}

test "#580 compiler_include_dirs: a path without glob characters is kept, existing or not" {
    try check("[\"no/such/dir\", \"other/include\"]", &.{ "no/such/dir", "other/include" });
}
