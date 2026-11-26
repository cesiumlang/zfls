//! Converting a file between fixed and free form with findent (#279): the
//! request `zfls/convertForm` and the source action that creates the
//! free-form file, with a stand-in for findent.

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;

const fixed_source = h.File{ .name = "old.f", .text =
    \\C     a fixed-form file
    \\      program p
    \\      x = 1 +
    \\     &    2
    \\      end
    \\
};

/// A stand-in for findent that prints its arguments, then its input
const stub: h.File = if (is_windows)
    .{ .name = "tools/findent.bat", .text = "@echo off\r\necho ARGS %*\r\nfindstr \"^\"\r\n" }
else
    .{ .name = "tools/findent", .text = "#!/bin/sh\necho \"ARGS $*\"\ncat\n" };

fn init(init_options: []const u8, create_files: bool) !*h.Workspace {
    const w = try h.Workspace.init(&.{ fixed_source, stub }, .{ .init_options = init_options, .create_files = create_files });
    if (!is_windows) try w.tmp.dir.setFilePermissions(std.testing.io, stub.name, .executable_file, .{});
    try w.open("old.f", "fortran");
    return w;
}

fn convertForm(w: *h.Workspace, to: []const u8) !h.json.Value {
    return w.zflsRequest("zfls/convertForm", .{ .textDocument = .{ .uri = try w.uri("old.f") }, .to = to });
}

test "zfls/convertForm runs findent with -ifixed -ofree, the user's arguments and the unsaved text (#279)" {
    const w = try init("{\"formatter\": \"findent\", \"formatter_path\": \"" ++ stub.name ++ "\", \"formatter_args\": [\"-i4\"]}", false);
    defer w.deinit();
    // an unsaved change
    _ = try w.zflsRequest("textDocument/didChange", .{
        .textDocument = .{ .uri = try w.uri("old.f"), .version = 2 },
        .contentChanges = &[_]struct { text: []const u8 }{.{ .text = "      program unsaved\n      end\n" }},
    });
    const v = try convertForm(w, "free");
    const text = h.json.str(h.json.get(v, "text")) orelse return error.NoText;
    try std.testing.expect(std.mem.find(u8, text, "-i4 -ifixed -ofree") != null);
    try std.testing.expect(std.mem.find(u8, text, "program unsaved") != null);
    const path = h.json.str(h.json.get(v, "path")) orelse return error.NoPath;
    try std.testing.expect(std.mem.endsWith(u8, path, "old.f90"));
    // and back: -ifree -ofixed
    const back = h.json.str(h.json.get(try convertForm(w, "fixed"), "text")) orelse return error.NoText;
    try std.testing.expect(std.mem.find(u8, back, "-ifree -ofixed") != null);
}

test "findent from formatter_path's directory when another formatter is configured (#279)" {
    const w = try init("{\"formatter\": \"fprettify\", \"formatter_path\": \"tools\", \"formatter_args\": [\"--indent\", \"4\"]}", false);
    defer w.deinit();
    const text = h.json.str(h.json.get(try convertForm(w, "free"), "text")) orelse return error.NoText;
    // fprettify's arguments are not findent's
    try std.testing.expect(std.mem.find(u8, text, "ARGS -ifixed -ofree") != null);
}

test "findent missing: an error that says how to install it (#279)" {
    const w = try init("{\"formatter\": \"findent\", \"formatter_path\": \"missing/findent.exe\"}", false);
    defer w.deinit();
    const v = try convertForm(w, "free");
    const err = h.json.str(h.json.get(v, "error")) orelse return error.NoError;
    try std.testing.expect(std.mem.find(u8, err, "pip install findent") != null);
}

fn convertActions(w: *h.Workspace) !usize {
    var n: usize = 0;
    for (try w.codeActionsOf("old.f", 0, 0, &.{"source"})) |act| {
        if (std.mem.startsWith(u8, act.title, "Convert to free form")) n += 1;
    }
    return n;
}

test "the source action that creates the free-form file: only for clients that create files (#279)" {
    const opts = "{\"enable_code_actions\": true, \"formatter\": \"findent\", \"formatter_path\": \"" ++ stub.name ++ "\"}";
    {
        const w = try init(opts, true);
        defer w.deinit();
        try std.testing.expectEqual(@as(usize, 1), try convertActions(w));
        // its edit creates old.f90 with the converted text
        const v = try w.zflsRequest("textDocument/codeAction", .{
            .textDocument = .{ .uri = try w.uri("old.f") },
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            .context = .{ .only = &[_][]const u8{"source"} },
        });
        var found = false;
        for (h.json.items(v)) |act| {
            const changes = h.json.items(h.json.path(act, &.{ "edit", "documentChanges" }) orelse continue);
            if (changes.len != 2) continue;
            try std.testing.expectEqualStrings("create", h.json.str(h.json.get(changes[0], "kind")) orelse "");
            try std.testing.expect(std.mem.endsWith(u8, h.json.str(h.json.get(changes[0], "uri")) orelse "", "old.f90"));
            const edit = h.json.items(h.json.get(changes[1], "edits"))[0];
            try std.testing.expect(std.mem.find(u8, h.json.str(h.json.get(edit, "newText")) orelse "", "-ifixed -ofree") != null);
            found = true;
        }
        try std.testing.expect(found);
    }
    {
        const w = try init(opts, false);
        defer w.deinit();
        try std.testing.expectEqual(@as(usize, 0), try convertActions(w));
    }
}

test "no conversion action for a free-form file (#279)" {
    const files = [_]h.File{ .{ .name = "new.f90", .text = "program p\nend program p\n" }, stub };
    const w = try h.Workspace.init(&files, .{ .init_options = "{\"enable_code_actions\": true, \"formatter\": \"findent\", \"formatter_path\": \"" ++ stub.name ++ "\"}", .create_files = true });
    defer w.deinit();
    for (try w.codeActionsOf("new.f90", 0, 0, &.{"source"})) |act| try std.testing.expect(!std.mem.startsWith(u8, act.title, "Convert"));
}

test "with findent: the converted file has the same outline as free form (#279)" {
    const src = [_]h.File{.{ .name = "old.f", .text =
        \\C     a module in fixed form
        \\      module m
        \\      implicit none
        \\      contains
        \\      subroutine s(a,
        \\     &             b)
        \\      integer a, b
        \\      a = b +
        \\     &    1
        \\      end subroutine
        \\      end module
        \\
    }};
    const w = try h.Workspace.init(&src, .{});
    defer w.deinit();
    try w.open("old.f", "fortran");
    const v = try convertForm(w, "free");
    if (h.json.get(v, "error")) |_| return error.SkipZigTest; // no findent here
    const text = h.json.str(h.json.get(v, "text")) orelse return error.NoText;
    const before = try w.documentSymbols("old.f");
    const converted = [_]h.File{.{ .name = "new.f90", .text = text }};
    const w2 = try h.Workspace.init(&converted, .{});
    defer w2.deinit();
    const after = try w2.documentSymbols("new.f90");
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |x, y| try std.testing.expectEqualStrings(x, y);
}
