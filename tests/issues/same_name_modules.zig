//! Modules of the same name in several directories (#187): a project that
//! builds several programs, each with its own `utils`. A file sees the one
//! its build puts on its module search path (compile_commands.json), else
//! the one in its directory, then in the nearest one.

const std = @import("std");
const h = @import("harness.zig");

fn utils(comptime tag: []const u8, comptime decl: []const u8) []const u8 {
    return
    \\module utils
    \\  implicit none
    \\
    ++ "  " ++ decl ++ " :: only_in_" ++ tag ++ " = 1\n" ++
        \\contains
        \\
    ++ "  subroutine helper_" ++ tag ++ "()\n  end subroutine helper_" ++ tag ++ "\nend module utils\n";
}

fn program(comptime tag: []const u8) []const u8 {
    return "program p_" ++ tag ++ "\n  use utils\n  implicit none\n  print *, only_in_" ++ tag ++ "\n  call helper_" ++ tag ++ "()\nend program p_" ++ tag ++ "\n";
}

const by_directory = [_]h.File{
    .{ .name = "app1/utils.f90", .text = utils("app1", "integer") },
    .{ .name = "app2/utils.f90", .text = utils("app2", "real") },
    .{ .name = "app1/main.f90", .text = program("app1") },
    .{ .name = "app2/main.f90", .text = program("app2") },
};

/// The checks of `main` (`app/main.f90`) seeing the `utils` of `want`
/// (`dir/utils.f90`), whose names end in `tag`, and not `other`'s
fn expectSees(w: *h.Workspace, main: []const u8, want: []const u8, tag: []const u8, other: []const u8, decl: []const u8) !void {
    const a = w.arena.allocator();
    // definition of the module and of a variable
    const d = (try w.definition(main, w.pos(main, "utils", 0, 0))) orelse return error.NoDefinition;
    if (!std.mem.endsWith(u8, d.uri, want)) {
        std.debug.print("\n{s}: utils is {s}, not {s}\n", .{ main, d.uri, want });
        return error.TestUnexpectedResult;
    }
    const v = try a.print("only_in_{s}", .{tag});
    const dv = (try w.definition(main, w.pos(main, v, 0, 0))) orelse return error.NoDefinition;
    try std.testing.expect(std.mem.endsWith(u8, dv.uri, want));
    // hover
    const text = (try w.hover(main, w.pos(main, v, 0, 0))) orelse return error.NoHover;
    if (std.ascii.findIgnoreCase(text, try a.print("{s} :: {s}", .{ decl, v })) == null) {
        std.debug.print("\nhover of {s} in {s}: {s}\n", .{ v, main, text });
        return error.TestUnexpectedResult;
    }
    // completion: its names, not the other's
    var mine = false;
    for (try w.completion(main, w.pos(main, v, 0, "only_in_".len))) |label| {
        if (std.mem.eql(u8, label, v)) mine = true;
        try std.testing.expect(std.mem.find(u8, label, other) == null);
    }
    try std.testing.expect(mine);
    // no diagnostics (an undeclared variable, an unknown subroutine)
    try w.open(main, "fortran");
    const diags = try w.diagnostics(main);
    for (diags) |x| std.debug.print("\n{s}:{d}: {s}\n", .{ main, x.line, x.message });
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "modules of the same name: each program sees the one in its directory (#187)" {
    const w = try h.Workspace.init(&by_directory, .{});
    defer w.deinit();
    try expectSees(w, "app1/main.f90", "app1/utils.f90", "app1", "app2", "INTEGER");
    try expectSees(w, "app2/main.f90", "app2/utils.f90", "app2", "app1", "REAL");
    // both are workspace symbols
    var n: usize = 0;
    for (try w.workspaceSymbols("utils")) |s| {
        if (std.mem.eql(u8, s, "utils")) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "modules of the same name: the one a file sees follows edits (#187)" {
    const w = try h.Workspace.init(&by_directory, .{});
    defer w.deinit();
    // app1's utils goes away: app1 sees app2's
    try w.changeOnDisk("app1/utils.f90", null);
    const d = (try w.definition("app1/main.f90", w.pos("app1/main.f90", "utils", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expect(std.mem.endsWith(u8, d.uri, "app2/utils.f90"));
    // and back
    try w.changeOnDisk("app1/utils.f90", utils("app1", "integer"));
    try expectSees(w, "app1/main.f90", "app1/utils.f90", "app1", "app2", "INTEGER");
}

const shared_sources = [_]h.File{
    .{ .name = "src/a/utils.f90", .text = utils("a", "integer") },
    .{ .name = "src/b/utils.f90", .text = utils("b", "real") },
    .{ .name = "app1/main.f90", .text = program("a") },
    .{ .name = "app2/main.f90", .text = program("b") },
};

test "modules of the same name: compile_commands.json's module directories decide (#187)" {
    const files = shared_sources ++ [_]h.File{.{ .name = "compile_commands.json", .text =
        \\[{"directory": ".", "file": "src/a/utils.f90", "arguments": ["gfortran", "-J", "build/a", "-c", "src/a/utils.f90"]},
        \\ {"directory": ".", "file": "src/b/utils.f90", "arguments": ["gfortran", "-Jbuild/b", "-c", "src/b/utils.f90"]},
        \\ {"directory": ".", "file": "app1/main.f90", "arguments": ["gfortran", "-Ibuild/a", "-Jbuild/app1", "-c", "app1/main.f90"]},
        \\ {"directory": ".", "file": "app2/main.f90", "arguments": ["gfortran", "-I", "build/b", "-Jbuild/app2", "-c", "app2/main.f90"]}]
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try expectSees(w, "app1/main.f90", "src/a/utils.f90", "a", "only_in_b", "INTEGER");
    try expectSees(w, "app2/main.f90", "src/b/utils.f90", "b", "only_in_a", "REAL");
}

test "modules of the same name: without build information, the nearest, then the first (#187)" {
    const w = try h.Workspace.init(&shared_sources, .{});
    defer w.deinit();
    // both equally near: the lowest path, as before
    inline for (.{ "app1/main.f90", "app2/main.f90" }) |main| {
        const d = (try w.definition(main, w.pos(main, "utils", 0, 0))) orelse return error.NoDefinition;
        try std.testing.expect(std.mem.endsWith(u8, d.uri, "src/a/utils.f90"));
    }
}
