//! Upstream issues about the workspace: indexing, configuration and
//! incremental updates.

const std = @import("std");
const h = @import("harness.zig");

test "#565 editing a file that is included by an include file" {
    const w = try h.Workspace.init(&.{
        .{ .name = "prog.f90", .text =
        \\program prog
        \\  implicit none
        \\  include 'mid.f90'
        \\  x = 1
        \\end program prog
        \\
        },
        .{ .name = "mid.f90", .text =
        \\include 'leaf.f90'
        \\
        },
        .{ .name = "leaf.f90", .text =
        \\integer :: x
        \\
        },
    }, .{ .settings = .{ .incremental_sync = true } });
    defer w.deinit();
    const outcome: anyerror!void = blk: {
        // open leaf.f90, change its text and save it
        w.replaceText("leaf.f90", "integer :: x, y\n") catch |e| break :blk h.unmet("the change failed: {s}", .{@errorName(e)});
        for (try w.messages()) |m| {
            if (std.mem.indexOf(u8, m, "failed") != null) break :blk h.unmet("the server reported: {s}", .{m});
        }
        break :blk {};
    };
    try h.check(565, .fixed, outcome);
}

test "#536 a configuration file does not discard the preprocessor definitions given on the command line" {
    const w = try h.Workspace.init(&.{
        .{ .name = ".fortlsrc", .text = "{}\n" },
        .{ .name = "main.F90", .text =
        \\#ifdef HAVE_FOO
        \\module foo_mod
        \\  implicit none
        \\end module foo_mod
        \\#endif
        \\program p
        \\end program p
        \\
        },
    }, .{ .pp_defs = &.{.{ .name = "HAVE_FOO", .value = "1" }} });
    defer w.deinit();
    const syms = try w.workspaceSymbols("foo_mod");
    try h.check(536, .fixed, h.expect(syms.len > 0, "foo_mod is not found: the config file dropped --pp_defs", .{}));
}

test "#558 an unreadable directory under a source_dirs glob is skipped" {
    const w = try h.Workspace.init(&.{
        .{ .name = ".fortlsrc", .text = "{\"source_dirs\": [\"./*\"]}\n" },
        .{ .name = "sub/bar.f90", .text =
        \\module bar_mod
        \\end module bar_mod
        \\
        },
    }, .{
        .unreadable = &.{"locked"},
    });
    defer w.deinit();
    const syms = try w.workspaceSymbols("bar_mod");
    try h.check(558, .fixed, h.expect(syms.len > 0, "bar_mod is not found: the unreadable directory broke indexing", .{}));
}

test "#536 a broken symlink under the workspace is skipped" {
    const w = try h.Workspace.init(&.{.{ .name = "sub/bar.f90", .text =
    \\module bar_mod
    \\end module bar_mod
    \\
    }}, .{
        .links = &.{.{ .name = "dangling.f90", .target = "does_not_exist.f90" }},
    });
    defer w.deinit();
    const syms = try w.workspaceSymbols("bar_mod");
    try h.check(536, .fixed, h.expect(syms.len > 0, "bar_mod is not found: the broken symlink broke indexing", .{}));
}

test "#301 an INCLUDE statement is searched in the include directories" {
    const w = try h.Workspace.init(&.{
        .{ .name = ".fortlsrc", .text =
        \\{"source_dirs": ["./**"], "incl_suffixes": [".inc"], "include_dirs": ["inc"]}
        \\
        },
        .{ .name = "src/main.f90", .text =
        \\program p
        \\  include 'consts.inc'
        \\  print *, n
        \\end program p
        \\
        },
        .{ .name = "inc/consts.inc", .text =
        \\integer, parameter :: n = 3
        \\
        },
    }, .{});
    defer w.deinit();
    const outcome: anyerror!void = blk: {
        const use = w.pos("src/main.f90", "n\n", 0, 0);
        w.expectHoverContains("src/main.f90", use, "INTEGER, PARAMETER :: n = 3") catch |e| break :blk e;
        const def = (try w.definition("src/main.f90", use)) orelse break :blk h.unmet("no definition for n", .{});
        h.expect(std.mem.endsWith(u8, def.uri, "consts.inc") and def.line == 0, "definition of n is {s}:{d}", .{ def.uri, def.line }) catch |e| break :blk e;
        // go to definition on the statement opens the file, as for `#include` (#498)
        const inc = (try w.definition("src/main.f90", w.pos("src/main.f90", "consts.inc", 0, 2))) orelse
            break :blk h.unmet("no definition for the INCLUDE statement", .{});
        break :blk h.expect(std.mem.endsWith(u8, inc.uri, "consts.inc"), "definition of the INCLUDE is {s}", .{inc.uri});
    };
    try h.check(301, .fixed, outcome);
}

test "an untitled document is served from the text the client sends" {
    const zfls = @import("zfls");
    const json = zfls.json;
    const w = try h.Workspace.init(&.{.{ .name = "lib.f90", .text =
    \\module lib
    \\  integer :: shared = 1
    \\end module lib
    \\
    }}, .{});
    defer w.deinit();
    const a = w.arena.allocator();
    const uri = "untitled:Untitled-1";
    _ = try w.server.dispatchPublic(a, "textDocument/didOpen", try json.from(a, .{ .textDocument = .{
        .uri = uri,
        .languageId = "FortranFreeForm",
        .version = 1,
        .text = "program p\n  use lib\n  integer :: mine\n  print *, shared, mine\nend program p\n",
    } }));
    const at = struct {
        fn params(al: std.mem.Allocator, line: usize, character: usize) !json.Value {
            return json.from(al, .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } });
        }
    };
    // a name from a workspace file: its file's URI
    const def = try w.server.dispatchPublic(a, "textDocument/definition", try at.params(a, 3, 12));
    try std.testing.expect(std.mem.endsWith(u8, json.str(json.get(def, "uri")) orelse "", "lib.f90"));
    // a name of the document itself: the document's URI
    const own = try w.server.dispatchPublic(a, "textDocument/definition", try at.params(a, 3, 20));
    try std.testing.expectEqualStrings(uri, json.str(json.get(own, "uri")) orelse "");
    try std.testing.expectEqual(@as(?i64, 2), json.int(json.path(own, &.{ "range", "start", "line" })));
    // its changes are applied
    _ = try w.server.dispatchPublic(a, "textDocument/didChange", try json.from(a, .{
        .textDocument = .{ .uri = uri, .version = 2 },
        .contentChanges = &[_]struct { text: []const u8 }{.{ .text = "program p\n  use lib\n  real :: mine\n  print *, shared, mine\nend program p\n" }},
    }));
    const hov = try w.server.dispatchPublic(a, "textDocument/hover", try at.params(a, 3, 20));
    try std.testing.expect(std.mem.indexOf(u8, json.str(json.path(hov, &.{ "contents", "value" })) orelse "", "REAL") != null);
    _ = try w.server.dispatchPublic(a, "textDocument/didClose", try json.from(a, .{ .textDocument = .{ .uri = uri } }));
}

fn watched(w: *h.Workspace, name: []const u8, kind: i64) !void {
    const zfls = @import("zfls");
    const a = w.arena.allocator();
    _ = try w.server.dispatchPublic(a, "workspace/didChangeWatchedFiles", try zfls.json.from(a, .{
        .changes = &[_]struct { uri: []const u8, type: i64 }{.{ .uri = try w.uri(name), .type = kind }},
    }));
}

fn hasSymbol(w: *h.Workspace, name: []const u8) !bool {
    for (try w.workspaceSymbols(name)) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

test "files changed, created and deleted outside the editor are followed" {
    const w = try h.Workspace.init(&.{.{ .name = "lib.f90", .text =
    \\module lib
    \\  integer :: old_name
    \\end module lib
    \\
    }}, .{});
    defer w.deinit();
    const io = std.testing.io;
    try std.testing.expect(try hasSymbol(w, "old_name"));
    // changed on disk (a checkout)
    try w.tmp.dir.writeFile(io, .{ .sub_path = "lib.f90", .data = "module lib\n  integer :: new_name\nend module lib\n" });
    try watched(w, "lib.f90", 2);
    try std.testing.expect(try hasSymbol(w, "new_name"));
    try std.testing.expect(!try hasSymbol(w, "old_name"));
    // created, in a directory that did not exist at start-up
    try w.tmp.dir.createDirPath(io, "gen");
    try w.tmp.dir.writeFile(io, .{ .sub_path = "gen/made.f90", .data = "module made\nend module made\n" });
    try watched(w, "gen/made.f90", 1);
    try std.testing.expect(try hasSymbol(w, "made"));
    // deleted
    try w.tmp.dir.deleteFile(io, "gen/made.f90");
    try watched(w, "gen/made.f90", 3);
    try std.testing.expect(!try hasSymbol(w, "made"));
    // restored as it was
    try w.tmp.dir.writeFile(io, .{ .sub_path = "gen/made.f90", .data = "module made\nend module made\n" });
    try watched(w, "gen/made.f90", 1);
    try std.testing.expect(try hasSymbol(w, "made"));
}

test "a document open in the editor keeps the editor's text when its file changes" {
    const zfls = @import("zfls");
    const w = try h.Workspace.init(&.{.{ .name = "lib.f90", .text =
    \\module lib
    \\  integer :: edited_name
    \\end module lib
    \\
    }}, .{});
    defer w.deinit();
    const a = w.arena.allocator();
    _ = try w.server.dispatchPublic(a, "textDocument/didOpen", try zfls.json.from(a, .{ .textDocument = .{ .uri = try w.uri("lib.f90") } }));
    try w.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib.f90", .data = "module lib\n  integer :: disk_name\nend module lib\n" });
    try watched(w, "lib.f90", 2);
    try std.testing.expect(try hasSymbol(w, "edited_name"));
    try std.testing.expect(!try hasSymbol(w, "disk_name"));
}
