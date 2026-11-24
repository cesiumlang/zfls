//! The project's own configuration file, `.zflsrc` (#900): TOML with the
//! options' names, looked for before the fortls names; `-c` takes either
//! format; unknown keys are warnings; it takes over from the user's file,
//! the editor and the command line, but names no program to run.

const std = @import("std");
const h = @import("harness.zig");
const user_config = @import("user_config.zig");

const program = [_]h.File{.{ .name = "c.f90", .text =
    \\module c
    \\contains
    \\  subroutine s(x)
    \\    real, intent(in) :: x
    \\    print *, x
    \\  end subroutine s
    \\end module c
    \\
}};

fn isLowercase(w: *h.Workspace) !bool {
    const text = (try w.hover("c.f90", w.pos("c.f90", "x\n", 1, 0))) orelse return error.NoHover;
    if (std.mem.find(u8, text, "real, intent(in) :: x") != null) return true;
    if (std.mem.find(u8, text, "REAL, INTENT(IN) :: x") != null) return false;
    return error.UnexpectedHover;
}

fn messageWith(w: *h.Workspace, needle: []const u8) !bool {
    for (try w.sentWith("window/showMessage")) |m| if (std.mem.find(u8, m, needle) != null) return true;
    return false;
}

test "a .zflsrc in TOML sets options, with comments and tables" {
    const files = program ++ [_]h.File{.{ .name = ".zflsrc", .text =
        \\# the project's options
        \\lowercase_hover = true  # as fortls's
        \\source_dirs = [
        \\  ".",
        \\]
        \\
        \\[pp_defs]
        \\FROM_TOML = 1
        \\
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try std.testing.expect(try isLowercase(w));
    try std.testing.expectEqualStrings("FROM_TOML", w.server.s.pp_defs.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), (try w.sentWith("window/showMessage")).len);
}

test ".zflsrc is read before the fortls names" {
    const files = program ++ [_]h.File{
        .{ .name = ".fortlsrc", .text = "{\"lowercase_hover\": false}\n" },
        .{ .name = ".zflsrc", .text = "lowercase_hover = true\n" },
    };
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try std.testing.expect(try isLowercase(w));
}

test "the fortls names still work" {
    const files = program ++ [_]h.File{.{ .name = ".fortlsrc", .text = "{\"lowercase_hover\": true}\n" }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try std.testing.expect(try isLowercase(w));
}

test "-c names a file of either format, told by its content" {
    const toml = program ++ [_]h.File{.{ .name = "mine.cfg", .text = "lowercase_hover = true\n" }};
    {
        const w = try h.Workspace.init(&toml, .{ .settings = .{ .config = "mine.cfg" } });
        defer w.deinit();
        try std.testing.expect(try isLowercase(w));
    }
    const json = program ++ [_]h.File{.{ .name = "mine.cfg", .text = "{\"lowercase_hover\": true}\n" }};
    const w = try h.Workspace.init(&json, .{ .settings = .{ .config = "mine.cfg" } });
    defer w.deinit();
    try std.testing.expect(try isLowercase(w));
}

test ".zflsrc takes over from the user's file, the editor and the command line" {
    const u = try user_config.UserConfig.init("{\"lowercase_hover\": false}");
    defer u.deinit();
    const files = program ++ [_]h.File{.{ .name = ".zflsrc", .text = "lowercase_hover = true\n" }};
    const w = try h.Workspace.init(&files, .{ .init_options = "{\"lowercase_hover\": false}" });
    defer w.deinit();
    try std.testing.expect(try isLowercase(w));
    try w.changeConfiguration("{\"lowercase_hover\": false}");
    try std.testing.expect(try isLowercase(w));
    const cli = try h.Workspace.init(&files, .{ .settings = .{ .lowercase_hover = false } });
    defer cli.deinit();
    try std.testing.expect(try isLowercase(cli));
}

test ".zflsrc leaves the options it does not set to the other sources, and keeps what fpm.toml adds" {
    const u = try user_config.UserConfig.init("{\"lowercase_hover\": true}");
    defer u.deinit();
    const files = program ++ [_]h.File{
        .{ .name = ".zflsrc", .text = "include_dirs = [\"inc\"]\n" },
        .{ .name = "fpm.toml", .text = "name = \"x\"\n[preprocess]\n[preprocess.cpp]\nmacros = [\"FROM_FPM=1\"]\n" },
    };
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try std.testing.expect(try isLowercase(w));
    var found = false;
    for (w.server.s.pp_defs.items) |d| found = found or std.mem.eql(u8, d.name, "FROM_FPM");
    try std.testing.expect(found);
}

test "an unknown key and a value of the wrong type are warnings" {
    const files = program ++ [_]h.File{.{ .name = ".zflsrc", .text = "lowercase_hover = true\nnthread = 2\nnotify_init = \"yes\"\n" }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try std.testing.expect(try messageWith(w, "unknown option nthread"));
    try std.testing.expect(try messageWith(w, "notify_init takes true or false"));
    // the rest is read
    try std.testing.expect(try isLowercase(w));
}

test "a syntax error in .zflsrc is reported, naming the file and the place" {
    const files = program ++ [_]h.File{.{ .name = ".zflsrc", .text = "lowercase_hover = \n" }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try std.testing.expect(try messageWith(w, "1:19 expected a value"));
    try std.testing.expect(try messageWith(w, ".zflsrc"));
}

test "a workspace's .zflsrc names no program to run (#890)" {
    const files = program ++ [_]h.File{.{ .name = ".zflsrc", .text = "compiler_diagnostics = \"gfortran\"\ncompiler_path = \"./evil\"\nformatter_path = \"./evil\"\ndebug_log = true\ncompiler_args = [\"-Wall\", \"-wrapper\", \"x\"]\n" }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try std.testing.expectEqualStrings("gfortran", w.server.s.compiler_diagnostics.?);
    try std.testing.expect(w.server.s.compiler_path == null);
    try std.testing.expect(w.server.s.formatter_path == null);
    try std.testing.expect(!w.server.s.debug_log);
    try std.testing.expectEqual(@as(usize, 1), w.server.s.compiler_args.?.len());
}
