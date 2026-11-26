//! More formatters (#278): `codee` (`codee format`), `forformat`, and a
//! `custom` command, with stand-in scripts for the tools; `formatter_fixed`
//! and `formatter_fixed_args` for fixed-form files (#741).

const std = @import("std");
const builtin = @import("builtin");
const h = @import("harness.zig");

const is_windows = builtin.target.os.tag == .windows;

const source = h.File{ .name = "a.f90", .text =
    \\program p
    \\x = 1
    \\y = 2
    \\end program p
    \\
};

/// A stand-in that numbers the lines of its input (`1:program p`)
const numbering: h.File = if (is_windows)
    .{ .name = "number.cmd", .text = "@echo off\r\nfindstr /n \"^\"\r\n" }
else
    .{ .name = "number.sh", .text = "#!/bin/sh\nawk '{print NR \":\" $0}'\n" };

/// A stand-in that prints its arguments
const echo: h.File = if (is_windows)
    .{ .name = "args.cmd", .text = "@echo off\r\necho %*\r\n" }
else
    .{ .name = "args.sh", .text = "#!/bin/sh\necho \"$@\"\n" };

/// A stand-in that fails with a message
const failing: h.File = if (is_windows)
    .{ .name = "fail.cmd", .text = "@echo off\r\necho bad input 1>&2\r\nexit /b 3\r\n" }
else
    .{ .name = "fail.sh", .text = "#!/bin/sh\necho 'bad input' >&2\nexit 3\n" };

const Edit = struct { line: i64, end_line: i64, text: []const u8 };

fn init(init_options: []const u8) !*h.Workspace {
    const w = try h.Workspace.init(&.{ source, numbering, echo, failing }, .{ .init_options = init_options });
    if (!is_windows) for ([_][]const u8{ numbering.name, echo.name, failing.name }) |n| {
        try w.tmp.dir.setFilePermissions(std.testing.io, n, .executable_file, .{});
    };
    try w.open("a.f90", "fortran");
    return w;
}

fn edits(w: *h.Workspace, range: ?[2]i64) ![]const Edit {
    const uri = try w.uri("a.f90");
    const v = if (range) |r| try w.zflsRequest("textDocument/rangeFormatting", .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = r[0], .character = 0 }, .end = .{ .line = r[1], .character = 3 } },
        .options = .{ .tabSize = 4, .insertSpaces = true },
    }) else try w.zflsRequest("textDocument/formatting", .{
        .textDocument = .{ .uri = uri },
        .options = .{ .tabSize = 4, .insertSpaces = true },
    });
    var out: std.ArrayList(Edit) = .empty;
    for (h.json.items(v)) |e| try out.append(std.heap.page_allocator, .{
        .line = h.json.int(h.json.path(e, &.{ "range", "start", "line" })) orelse -1,
        .end_line = h.json.int(h.json.path(e, &.{ "range", "end", "line" })) orelse -1,
        .text = h.json.str(h.json.get(e, "newText")) orelse "",
    });
    return out.items;
}

fn allText(es: []const Edit) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (es) |e| try out.appendSlice(std.heap.page_allocator, e.text);
    return out.items;
}

fn options(comptime formatter: []const u8, comptime path_key: []const u8, comptime path: []const u8, comptime args: []const u8) []const u8 {
    return "{\"formatter\": \"" ++ formatter ++ "\", \"" ++ path_key ++ "\": \"" ++ path ++ "\", \"formatter_args\": " ++ args ++ "}";
}

test "a custom formatter: its output replaces the document, and a selection's lines (#278)" {
    const w = try init(comptime options("custom", "formatter_path", numbering.name, "[]"));
    defer w.deinit();
    const whole = try allText(try edits(w, null));
    try std.testing.expect(std.mem.find(u8, whole, "1:") != null);
    try std.testing.expect(std.mem.find(u8, whole, "4:") != null);
    // a selection of lines 1 and 2: they are numbered 1 and 2, the others
    // are left alone
    const sel = try edits(w, .{ 1, 2 });
    for (sel) |e| try std.testing.expect(e.line >= 1 and e.end_line <= 3);
    const text = try allText(sel);
    try std.testing.expect(std.mem.find(u8, text, "1:") != null and std.mem.find(u8, text, "2:") != null);
    try std.testing.expect(std.mem.find(u8, text, "3:") == null);
}

test "a custom formatter's arguments: ${file} and ${form} (#278)" {
    const w = try init(comptime options("custom", "formatter_path", echo.name, "[\"--file=${file}\", \"--form=${form}\"]"));
    defer w.deinit();
    const text = try allText(try edits(w, null));
    try std.testing.expect(std.mem.find(u8, text, "--form=free") != null);
    try std.testing.expect(std.mem.find(u8, text, "a.f90") != null);
}

test "codee format runs codee_path's codee with format - -o - (#278)" {
    const w = try init("{\"formatter\": \"codee\", \"codee_path\": \"" ++ echo.name ++ "\"}");
    defer w.deinit();
    const text = try allText(try edits(w, null));
    try std.testing.expect(std.mem.find(u8, text, "format - -o -") != null);
}

test "forformat gets the file name and the form (#278)" {
    const w = try init(comptime options("forformat", "formatter_path", echo.name, "[]"));
    defer w.deinit();
    const text = try allText(try edits(w, null));
    try std.testing.expect(std.mem.find(u8, text, "--stdin-filename=") != null);
    try std.testing.expect(std.mem.find(u8, text, "a.f90") != null);
    try std.testing.expect(std.mem.find(u8, text, "-ifree") != null);
}

test "a formatter of whole files formats a selection with the rest of the file (#278)" {
    // forformat formats whole files: line 2 is the file's third line
    const w = try init(comptime options("forformat", "formatter_path", numbering.name, "[]"));
    defer w.deinit();
    const sel = try edits(w, .{ 2, 2 });
    try std.testing.expect(sel.len > 0);
    for (sel) |e| try std.testing.expect(e.line == 2 and e.end_line <= 3);
    try std.testing.expect(std.mem.find(u8, try allText(sel), "3:") != null);
}

test "a formatter that fails changes nothing and says why once (#278)" {
    const w = try init(comptime options("custom", "formatter_path", failing.name, "[]"));
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try edits(w, null)).len);
    try std.testing.expectEqual(@as(usize, 0), (try edits(w, null)).len);
    var n: usize = 0;
    for (try w.sentWith("window/showMessage")) |m| if (std.mem.find(u8, m, "bad input") != null) {
        n += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "a custom formatter without formatter_path says so (#278)" {
    const w = try init("{\"formatter\": \"custom\"}");
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try edits(w, null)).len);
    var found = false;
    for (try w.sentWith("window/showMessage")) |m| found = found or std.mem.find(u8, m, "formatter_path") != null;
    try std.testing.expect(found);
}

test "an unknown formatter is named with all those zfls knows (#278)" {
    const w = try init("{\"formatter\": \"black\"}");
    defer w.deinit();
    var found = false;
    for (try w.sentWith("window/showMessage")) |m| found = found or std.mem.find(u8, m, "findent, fprettify, codee, forformat or custom") != null;
    try std.testing.expect(found);
}

test "formatter_fixed formats fixed-form files with formatter_fixed_args, free form keeps formatter's (#741)" {
    const fixed_src = h.File{ .name = "b.f", .text = "      program p\n      x = 1\n      end program p\n" };
    const opts = "\"formatter_path\": \"" ++ echo.name ++ "\", \"formatter_args\": [\"--free-args\"], \"formatter_fixed_args\": [\"--fixed-args\"]";
    // fprettify formats no fixed form: without formatter_fixed, nothing
    inline for (.{ "", ", \"formatter_fixed\": \"custom\"" }, .{ false, true }) |fixed_option, formatted| {
        const w = try h.Workspace.init(&.{ source, fixed_src, echo }, .{ .init_options = "{\"formatter\": \"fprettify\", " ++ opts ++ fixed_option ++ "}" });
        defer w.deinit();
        if (!is_windows) try w.tmp.dir.setFilePermissions(std.testing.io, echo.name, .executable_file, .{});
        try w.open("b.f", "fortran");
        const v = try w.zflsRequest("textDocument/formatting", .{
            .textDocument = .{ .uri = try w.uri("b.f") },
            .options = .{ .tabSize = 4, .insertSpaces = true },
        });
        var text: std.ArrayList(u8) = .empty;
        for (h.json.items(v)) |e| try text.appendSlice(w.a(), h.json.str(h.json.get(e, "newText")) orelse "");
        try std.testing.expectEqual(formatted, std.mem.find(u8, text.items, "--fixed-args") != null);
        try std.testing.expect(std.mem.find(u8, text.items, "--free-args") == null);
    }
}
