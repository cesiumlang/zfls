//! A path of 32768 or more characters, in a source file, a configuration
//! file or a URI, is an error that is handled, not a crash (#893).

const std = @import("std");
const h = @import("harness.zig");

const long_len = 40000;

fn longName(a: std.mem.Allocator) ![]u8 {
    const name = try a.alloc(u8, long_len);
    @memset(name, 'a');
    return name;
}

test "an include of a very long name is skipped (#893)" {
    const a = std.testing.allocator;
    const name = try longName(a);
    defer a.free(name);
    const src = try a.print("program p\n  include '{s}'\n  integer :: x\nend program\n", .{name});
    defer a.free(src);
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = src }}, .{});
    defer w.deinit();
    try w.open("t.f90", "fortran");
    _ = try w.documentLinks("t.f90");
    _ = try w.hover("t.f90", w.pos("t.f90", "x", 0, 0));
}

test "a preprocessor include of a very long name is skipped (#893)" {
    const a = std.testing.allocator;
    const name = try longName(a);
    defer a.free(name);
    const src = try a.print("#include \"{s}\"\nprogram p\n  integer :: x\nend program\n", .{name});
    defer a.free(src);
    const w = try h.Workspace.init(&.{.{ .name = "t.F90", .text = src }}, .{});
    defer w.deinit();
    try w.open("t.F90", "fortran");
    _ = try w.hover("t.F90", w.pos("t.F90", "x", 0, 0));
}

test "very long paths in the configuration files are ignored (#893)" {
    const a = std.testing.allocator;
    const name = try longName(a);
    defer a.free(name);
    const rc = try a.print("{{\"include_dirs\": [\"{0s}\"], \"source_dirs\": [\"{0s}\"], \"excl_paths\": [\"{0s}\"]}}", .{name});
    defer a.free(rc);
    const fpm = try a.print("name = \"x\"\n[library]\nsource-dir = \"{0s}\"\n", .{name});
    defer a.free(fpm);
    const cc = try a.print("[{{\"directory\": \"{0s}\", \"file\": \"t.f90\", \"arguments\": [\"gfortran\", \"-I{0s}\", \"-c\", \"t.f90\"]}}]", .{name});
    defer a.free(cc);
    const w = try h.Workspace.init(&.{
        .{ .name = "t.f90", .text = "program p\n  integer :: x\nend program\n" },
        .{ .name = ".fortlsrc", .text = rc },
        .{ .name = "fpm.toml", .text = fpm },
        .{ .name = "compile_commands.json", .text = cc },
    }, .{});
    defer w.deinit();
    try w.open("t.f90", "fortran");
    _ = try w.hover("t.f90", w.pos("t.f90", "x", 0, 0));
}

test "a document with a very long URI is handled (#893)" {
    const a = std.testing.allocator;
    const name = try longName(a);
    defer a.free(name);
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = "program p\nend program\n" }}, .{});
    defer w.deinit();
    const uri = try a.print("file:///C:/{s}/x.f90", .{name});
    defer a.free(uri);
    _ = try w.request("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "fortran", .version = 1, .text = "program a\nend program\n" } });
    _ = try w.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 0, .character = 3 } });
}
