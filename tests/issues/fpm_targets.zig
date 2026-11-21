//! `zfls/fpmTargets`: each fpm project's executables, tests and examples,
//! for an editor's tasks and Run/Debug of fpm targets (zfls #579). The
//! cases of the VS Code extension's unit tests of its own fpm.toml reader,
//! which this replaces.

const std = @import("std");
const h = @import("harness.zig");

const manifest =
    \\name = "demo"   # the package
    \\version = "0.1.0"
    \\
    \\[build]
    \\auto-examples = false
    \\
    \\[[executable]]
    \\name = "second"
    \\source-dir = "app2"
    \\main = "main.f90"
    \\
    \\[[test]]
    \\name = 'unit'
    \\source-dir = "tests/unit"
    \\
    \\[dev-dependencies]
    \\test-drive.git = "https://github.com/fortran-lang/test-drive"
    \\
;

const program = "program p\nend program p\n";

/// Each project and its targets: `name kind target-name main [auto]`
fn listed(a: std.mem.Allocator, w: *h.Workspace) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const root = try w.uri("");
    for (h.json.items(try w.zflsRequest("zfls/fpmTargets", .{}))) |p| {
        const auto = h.json.get(p, "auto").?;
        try out.print(a, "{s} auto:{}{}{}\n", .{
            h.json.str(h.json.get(p, "name")).?,
            h.json.get(auto, "executable").?.bool,
            h.json.get(auto, "test").?.bool,
            h.json.get(auto, "example").?.bool,
        });
        for (h.json.items(h.json.get(p, "targets"))) |t| {
            const uri = h.json.str(h.json.get(t, "uri")).?;
            const rel = std.mem.trimStart(u8, if (std.mem.startsWith(u8, uri, root)) uri[root.len..] else uri, "/");
            const auto_target = h.json.get(t, "auto").?.bool;
            try out.print(a, "  {s} {s} {s}{s}\n", .{ h.json.str(h.json.get(t, "kind")).?, h.json.str(h.json.get(t, "name")).?, rel, if (auto_target) " (auto)" else "" });
        }
    }
    return out.items;
}

test "zfls/fpmTargets: fpm.toml's targets, the programs fpm finds, and the [build] switches" {
    const w = try h.Workspace.init(&.{
        .{ .name = "fpm.toml", .text = manifest },
        .{ .name = "app2/main.f90", .text = program },
        .{ .name = "tests/unit/main.f90", .text = program },
        // found by fpm: named after the file
        .{ .name = "app/tool.f90", .text = program },
        .{ .name = "test/sub/check.F90", .text = program },
        // auto-examples = false; a module, not a program
        .{ .name = "example/ex1.f90", .text = program },
        .{ .name = "app/helpers.f90", .text = "module helpers\nend module helpers\n" },
        .{ .name = "src/lib.f90", .text = "module lib\nend module lib\n" },
        // a dependency fpm fetched: not a project of the workspace
        .{ .name = "build/dependencies/test-drive/fpm.toml", .text = "name = \"test-drive\"\n" },
    }, .{});
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        \\demo auto:truetruefalse
        \\  executable second app2/main.f90
        \\  executable tool app/tool.f90 (auto)
        \\  test check test/sub/check.F90 (auto)
        \\  test unit tests/unit/main.f90
        \\
    , try listed(arena.allocator(), w));
}

test "zfls/fpmTargets: fpm.toml with a UTF-8 byte-order mark (#407), and a project's name from its directory" {
    const w = try h.Workspace.init(&.{
        .{ .name = "lib/fpm.toml", .text = "\u{FEFF}[build]\nauto-examples = false\n" },
        .{ .name = "lib/example/ex.f90", .text = program },
    }, .{});
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("lib auto:truetruefalse\n", try listed(arena.allocator(), w));
}
