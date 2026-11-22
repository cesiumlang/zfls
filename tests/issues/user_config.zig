//! The user's configuration file (#271): `%APPDATA%\zfls\config.json` on
//! Windows, `$XDG_CONFIG_HOME/zfls/config.json` elsewhere. Its settings
//! take over from the command line's; the editor's and the project's
//! configuration file take over from it.

const std = @import("std");
const h = @import("harness.zig");
const zfls = @import("zfls");

const gpa = std.testing.allocator;
const io = std.testing.io;

/// A user configuration file with `text` (none when null) in a temporary
/// directory, which the environment of zfls names, until `deinit`
const UserConfig = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,

    fn init(text: ?[]const u8) !*UserConfig {
        const u = try gpa.create(UserConfig);
        u.tmp = std.testing.tmpDir(.{});
        u.arena = .init(gpa);
        const a = u.arena.allocator();
        if (text) |t| {
            try u.tmp.dir.createDirPath(io, "zfls");
            try u.tmp.dir.writeFile(io, .{ .sub_path = "zfls/config.json", .data = t });
        }
        const dir = try u.tmp.dir.realPathFileAlloc(io, ".", a);
        var env = std.process.Environ.Map.init(a);
        try env.put("APPDATA", dir);
        try env.put("XDG_CONFIG_HOME", dir);
        zfls.paths.initUserConfig(a, &env);
        return u;
    }

    fn path(_: *UserConfig) []const u8 {
        return zfls.paths.userConfigFile().?;
    }

    fn write(u: *UserConfig, text: []const u8) !void {
        try u.tmp.dir.createDirPath(io, "zfls");
        try u.tmp.dir.writeFile(io, .{ .sub_path = "zfls/config.json", .data = text });
    }

    fn deinit(u: *UserConfig) void {
        var none = std.process.Environ.Map.init(gpa);
        defer none.deinit();
        zfls.paths.initUserConfig(gpa, &none);
        u.arena.deinit();
        u.tmp.cleanup();
        gpa.destroy(u);
    }
};

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
    std.debug.print("\nunexpected hover: {s}\n", .{text});
    return error.UnexpectedHover;
}

test "the user's configuration file sets options (#271)" {
    const u = try UserConfig.init("{\"lowercase_hover\": true}");
    defer u.deinit();
    const w = try h.Workspace.init(&program, .{});
    defer w.deinit();
    try std.testing.expect(try isLowercase(w));
    try std.testing.expectEqual(@as(usize, 0), (try w.sentWith("window/showMessage")).len);
}

test "the project's configuration file and the editor take over from the user's (#271)" {
    const u = try UserConfig.init("{\"lowercase_hover\": true}");
    defer u.deinit();
    {
        const files = program ++ [_]h.File{.{ .name = ".fortlsrc", .text = "{\"lowercase_hover\": false}\n" }};
        const w = try h.Workspace.init(&files, .{});
        defer w.deinit();
        try std.testing.expect(!try isLowercase(w));
    }
    {
        const w = try h.Workspace.init(&program, .{ .init_options = "{\"lowercase_hover\": false}" });
        defer w.deinit();
        try std.testing.expect(!try isLowercase(w));
        // and after a change of the editor's settings, the user's file again
        try w.changeConfiguration("{}");
        try std.testing.expect(try isLowercase(w));
    }
    {
        // over the command line
        const w = try h.Workspace.init(&program, .{ .settings = .{ .lowercase_hover = false } });
        defer w.deinit();
        try std.testing.expect(try isLowercase(w));
    }
}

test "the VS Code extension's settings take over from the user's file at start and after a change (#782)" {
    const u = try UserConfig.init("{\"lowercase_hover\": false}");
    defer u.deinit();
    // as the extension starts zfls: its settings on the command line and
    // as initializationOptions
    const settings = "{\"zfls\": {\"lowercase_hover\": true}}";
    const w = try h.Workspace.init(&program, .{ .settings = .{ .lowercase_hover = true }, .init_options = settings });
    defer w.deinit();
    try std.testing.expect(try isLowercase(w));
    try w.changeConfiguration(settings);
    try std.testing.expect(try isLowercase(w));
}

test "no user's configuration file: no message, the defaults (#271)" {
    const u = try UserConfig.init(null);
    defer u.deinit();
    const w = try h.Workspace.init(&program, .{});
    defer w.deinit();
    try std.testing.expect(!try isLowercase(w));
    try std.testing.expectEqual(@as(usize, 0), (try w.sentWith("window/showMessage")).len);
}

test "a syntax error in the user's configuration file is reported, naming it (#271)" {
    const u = try UserConfig.init("{\"lowercase_hover\": tru }");
    defer u.deinit();
    const files = program ++ [_]h.File{.{ .name = ".fortlsrc", .text = "{\"hover_signature\": true}\n" }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    const msgs = try w.sentWith("window/showMessage");
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    // (its backslashes escaped in the JSON text)
    try std.testing.expect(std.mem.find(u8, msgs[0], "config.json") != null and std.mem.find(u8, msgs[0], "while reading") != null);
    // the other settings still apply
    try std.testing.expect(!try isLowercase(w));
    try std.testing.expect(w.server.s.hover_signature);
}

test "the user's configuration file is watched and read again (#271)" {
    const u = try UserConfig.init("{}");
    defer u.deinit();
    const w = try h.Workspace.init(&program, .{ .watch_registration = true });
    defer w.deinit();
    _ = try w.zflsRequest("initialized", .{});
    const regs = try w.sentWith("client/registerCapability");
    try std.testing.expectEqual(@as(usize, 1), regs.len);
    try std.testing.expect(std.mem.find(u8, regs[0], "\"pattern\":\"config.json\"") != null);
    try std.testing.expect(!try isLowercase(w));
    try u.write("{\"lowercase_hover\": true}");
    _ = try w.zflsRequest("workspace/didChangeWatchedFiles", .{
        .changes = &[_]struct { uri: []const u8, type: i64 }{.{ .uri = try zfls.paths.pathToUri(w.arena.allocator(), u.path()), .type = 2 }},
    });
    try std.testing.expect(try isLowercase(w));
}

test "--debug_log names the configuration files read (#271)" {
    const u = try UserConfig.init("{\"max_line_length\": 81}");
    defer u.deinit();
    const files = program ++ [_]h.File{.{ .name = ".fortlsrc", .text = "{}\n" }};
    const w = try h.Workspace.init(&files, .{ .settings = .{ .debug_log = true } });
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, try w.path("fortls_debug.log"), arena.allocator(), .limited(1 << 24));
    const line_start = std.mem.find(u8, text, "Configuration files read: ") orelse return error.NoLine;
    const line = text[line_start .. std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len];
    try std.testing.expect(std.mem.find(u8, line, u.path()) != null);
    try std.testing.expect(std.mem.find(u8, line, ".fortlsrc") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"max_line_length\":81") != null);
}

test "the debug requests read the user's configuration file (#271)" {
    const u = try UserConfig.init("{\"pp_defs\": {\"FROMUSER\": \"\"}}");
    defer u.deinit();
    const w = try h.Workspace.init(&.{.{ .name = "a.F90", .text =
        \\module m
        \\#ifdef FROMUSER
        \\integer :: yes_user
        \\#endif
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = try zfls.debug.runTo(gpa, io, .{ .debug_parser = true, .debug_filepath = try w.path("a.F90"), .debug_rootpath = w.root }, .{ .a = gpa, .out = &out });
    try std.testing.expect(std.mem.find(u8, out.items, "integer :: yes_user !!! VARIABLE") != null);
}
