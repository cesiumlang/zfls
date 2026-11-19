//! compile_commands.json: the Fortran files it compiles outside the
//! workspace root are indexed too (#267), as a sibling library or a fetched
//! dependency of a CMake project.

const std = @import("std");
const h = @import("harness.zig");
const zfls = @import("zfls");

const gpa = std.testing.allocator;
const io = std.testing.io;

const main_text =
    \\program p
    \\   use extmod, only: extval
    \\   implicit none
    \\   print *, extval
    \\end program
    \\
;

/// A directory outside the workspace with `extmod.f90` and `c.c`
const Outside = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    /// its path, and as a JSON string's text
    dir: []const u8,
    json_dir: []const u8,

    fn init() !*Outside {
        const o = try gpa.create(Outside);
        o.tmp = std.testing.tmpDir(.{});
        o.arena = .init(gpa);
        const a = o.arena.allocator();
        try o.tmp.dir.writeFile(io, .{ .sub_path = "extmod.f90", .data =
            \\module extmod
            \\   implicit none
            \\   integer :: extval = 1
            \\end module
            \\
        });
        try o.tmp.dir.writeFile(io, .{ .sub_path = "c.c", .data = "module cmod\nend module\n" });
        o.dir = try o.tmp.dir.realPathFileAlloc(io, ".", a);
        o.json_dir = try std.mem.replaceOwned(u8, a, o.dir, "\\", "\\\\");
        return o;
    }

    fn deinit(o: *Outside) void {
        o.arena.deinit();
        o.tmp.cleanup();
        gpa.destroy(o);
    }

    /// A compile_commands.json compiling `file` (in `directory`) and main.f90
    fn database(o: *Outside, directory: []const u8, file: []const u8) ![]const u8 {
        return o.arena.allocator().print(
            \\[{{"directory": "{s}", "file": "{s}", "arguments": ["gfortran", "-c", "{s}"]}},
            \\ {{"directory": ".", "file": "main.f90", "arguments": ["gfortran", "-c", "main.f90"]}}]
        , .{ directory, file, file });
    }

    fn absolute(o: *Outside, name: []const u8) ![]const u8 {
        return o.arena.allocator().print("{s}{s}{s}", .{ o.json_dir, if (@import("builtin").target.os.tag == .windows) "\\\\" else "/", name });
    }
};

fn notFound(w: *h.Workspace) !bool {
    for (try w.diagnostics("main.f90")) |d| if (std.mem.find(u8, d.message, "Module \"extmod\" not found") != null) return true;
    return false;
}

test "a compilation database's sources outside the root are indexed (#267)" {
    const o = try Outside.init();
    defer o.deinit();
    const files = [_]h.File{
        .{ .name = "main.f90", .text = main_text },
        .{ .name = "compile_commands.json", .text = try o.database(o.json_dir, try o.absolute("extmod.f90")) },
    };
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("main.f90", "fortran");
    try std.testing.expect(!try notFound(w));
    const hover = (try w.hover("main.f90", w.pos("main.f90", "extval\n", 0, 0))) orelse return error.NoHover;
    if (std.mem.find(u8, hover, "INTEGER :: extval") == null) {
        std.debug.print("\nhover: {s}\n", .{hover});
        return error.TestUnexpectedResult;
    }
    const d = (try w.definition("main.f90", w.pos("main.f90", "extmod", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expect(std.mem.endsWith(u8, d.uri, "/extmod.f90"));

    // and no longer when the database drops it
    try w.changeOnDisk("compile_commands.json", "[]");
    try std.testing.expect(try notFound(w));
}

test "a relative file of an entry is relative to its directory (#267)" {
    const o = try Outside.init();
    defer o.deinit();
    const files = [_]h.File{
        .{ .name = "main.f90", .text = main_text },
        .{ .name = "compile_commands.json", .text = try o.database(o.json_dir, "extmod.f90") },
    };
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("main.f90", "fortran");
    try std.testing.expect(!try notFound(w));
}

test "a C file of the database, an excluded one, or no database: not read (#267)" {
    const o = try Outside.init();
    defer o.deinit();
    {
        const files = [_]h.File{
            .{ .name = "main.f90", .text = main_text },
            .{ .name = "compile_commands.json", .text = try o.database(o.json_dir, try o.absolute("c.c")) },
        };
        const w = try h.Workspace.init(&files, .{});
        defer w.deinit();
        try std.testing.expectEqual(@as(usize, 0), (try w.workspaceSymbols("cmod")).len);
    }
    const files = [_]h.File{
        .{ .name = "main.f90", .text = main_text },
        .{ .name = "compile_commands.json", .text = try o.database(o.json_dir, try o.absolute("extmod.f90")) },
    };
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var s: zfls.settings.Settings = .{};
        try s.excl_paths.add(arena.allocator(), o.dir);
        const w = try h.Workspace.init(&files, .{ .settings = s });
        defer w.deinit();
        try w.open("main.f90", "fortran");
        try std.testing.expect(try notFound(w));
    }
    {
        const w = try h.Workspace.init(&files, .{ .settings = .{ .disable_compile_commands = true } });
        defer w.deinit();
        try w.open("main.f90", "fortran");
        try std.testing.expect(try notFound(w));
    }
}
