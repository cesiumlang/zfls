//! The command line's debug requests (`--debug_parser`, `--debug_preproc`)
//! take the preprocessor options as the server does: the command line's,
//! with the configuration file's over them (#236); and the debug log names
//! the options in effect.

const std = @import("std");
const h = @import("harness.zig");
const zfls = @import("zfls");
const Settings = zfls.settings.Settings;

const gpa = std.testing.allocator;
const io = std.testing.io;

const files = [_]h.File{
    .{ .name = "main.F90", .text =
    \\#ifdef HAVE_FOO
    \\module foo_mod
    \\end module
    \\#endif
    \\
    },
    .{ .name = "main2.F90", .text =
    \\#include "defs.h"
    \\module m2
    \\end module
    \\
    },
    .{ .name = "inc/defs.h", .text = "#define Y 2\n" },
    .{ .name = "plain.f90", .text =
    \\#define X 1
    \\module pl
    \\end module
    \\
    },
};

const cfg_files = [_]h.File{
    .{ .name = ".fortls.json", .text = "{\"pp_defs\": {\"FROMCFG\": \"7\"}}\n" },
    .{ .name = "a.F90", .text =
    \\module m
    \\#ifdef FROMCFG
    \\integer :: yes_cfg
    \\#else
    \\integer :: no_cfg
    \\#endif
    \\end module
    \\
    },
};

/// The output of the debug request of `s` on `name` of `w`, rooted in `w`
fn debugRun(w: *h.Workspace, name: []const u8, s_in: Settings) ![]const u8 {
    var s = s_in;
    s.debug_filepath = try w.path(name);
    s.debug_rootpath = w.root;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = try zfls.debug.runTo(gpa, io, s, .{ .a = gpa, .out = &out });
    return std.testing.allocator.dupe(u8, out.items);
}

fn expectIn(text: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, text, needle) == null) {
        std.debug.print("\n'{s}' not in:\n{s}\n", .{ needle, text });
        return error.TestExpectedEqual;
    }
}

test "--debug_parser and --debug_preproc take --pp_defs, --include_dirs and --pp_suffixes (#236)" {
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var defs: Settings = .{ .debug_parser = true };
    try defs.setPpDef(a, "HAVE_FOO", "");
    const parsed = try debugRun(w, "main.F90", defs);
    defer gpa.free(parsed);
    try expectIn(parsed, "#ifdef HAVE_FOO !!! Conditional TRUE(1)");
    try expectIn(parsed, "module foo_mod !!! MODULE - Ln:2");

    defs.debug_parser = false;
    defs.debug_preproc = true;
    const preproc = try debugRun(w, "main.F90", defs);
    defer gpa.free(preproc);
    // no lines skipped
    try std.testing.expect(std.mem.find(u8, preproc, "[1, 4]") == null);
    try expectIn(preproc, "  HAVE_FOO = \n");

    var inc: Settings = .{ .debug_parser = true };
    try inc.include_dirs.add(a, "inc");
    const included = try debugRun(w, "main2.F90", inc);
    defer gpa.free(included);
    try std.testing.expect(std.mem.find(u8, included, "Could not locate include file") == null);

    var sfx: Settings = .{ .debug_parser = true, .pp_suffixes = .{} };
    try sfx.pp_suffixes.?.add(a, ".f90");
    const defined = try debugRun(w, "plain.f90", sfx);
    defer gpa.free(defined);
    try expectIn(defined, "#define X 1 !!! Define statement(1)");
}

test "--debug_parser reads .fortls.json (#236)" {
    const w = try h.Workspace.init(&cfg_files, .{});
    defer w.deinit();
    const parsed = try debugRun(w, "a.F90", .{ .debug_parser = true });
    defer gpa.free(parsed);
    try expectIn(parsed, ".fortls.json\n");
    try expectIn(parsed, "integer :: yes_cfg !!! VARIABLE - Ln:3");
}

/// The lines of fortls_debug.log in `w` that name the final options
fn finalOptions(w: *h.Workspace) ![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, try w.path("fortls_debug.log"), arena.allocator(), .limited(1 << 24));
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| if (std.mem.find(u8, l, "Final options: {") != null) try out.append(gpa, try gpa.dupe(u8, l));
    return out.toOwnedSlice(gpa);
}

fn freeLines(lines: []const []const u8) void {
    for (lines) |l| gpa.free(l);
    gpa.free(lines);
}

test "the debug log names the final options, at start and after a change (#236)" {
    const w = try h.Workspace.init(&cfg_files, .{ .settings = .{ .debug_log = true, .max_line_length = 77 } });
    defer w.deinit();
    {
        const lines = try finalOptions(w);
        defer freeLines(lines);
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        // from the command line, and from the configuration file
        try expectIn(lines[0], "\"max_line_length\":77");
        try expectIn(lines[0], "\"pp_defs\":{\"FROMCFG\":\"7\"}");
    }
    try w.changeConfiguration("{\"max_comment_line_length\": 55}");
    const lines = try finalOptions(w);
    defer freeLines(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try expectIn(lines[1], "\"max_comment_line_length\":55");
}

test "--debug_log of a debug request names the final options (#236)" {
    const w = try h.Workspace.init(&cfg_files, .{});
    defer w.deinit();
    const out = try debugRun(w, "a.F90", .{ .debug_symbols = true, .debug_log = true, .max_line_length = 66 });
    defer gpa.free(out);
    const lines = try finalOptions(w);
    defer freeLines(lines);
    try std.testing.expect(lines.len >= 1);
    try expectIn(lines[0], "\"max_line_length\":66");
    try expectIn(lines[0], "\"FROMCFG\":\"7\"");
}
