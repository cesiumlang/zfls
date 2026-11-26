//! The external tools for real (#739): fortitude, fypp, findent and
//! fprettify, each found on the PATH as zfls finds it; a test is skipped
//! where its tool is not there. CI installs them on Linux x64 (ci.yml).

const std = @import("std");
const h = @import("harness.zig");
const tools = @import("tools.zig");

const free = h.File{ .name = "a.f90", .text = "program p\nx=1+2\nend program p\n" };
const fixed = h.File{ .name = "b.f", .text = "      program p\n      if (.true.) then\n      x = 1\n      end if\n      end program p\n" };

/// The offset of a 0-based line and character in `text`
fn offsetOf(text: []const u8, line: i64, character: i64) usize {
    var at: usize = 0;
    var l: i64 = 0;
    while (l < line) : (l += 1) at = (std.mem.findScalarPos(u8, text, at, '\n') orelse return text.len) + 1;
    return @min(text.len, at + @as(usize, @intCast(character)));
}

/// `name` once formatted: its text with the edits of
/// `textDocument/formatting` made, the last first
fn formatted(w: *h.Workspace, name: []const u8) ![]const u8 {
    try w.open(name, "fortran");
    const v = try w.request("textDocument/formatting", .{
        .textDocument = .{ .uri = try w.uri(name) },
        .options = .{ .tabSize = 4, .insertSpaces = true },
    });
    for (try w.messages()) |m| std.debug.print("\n{s}\n", .{m});
    var text: []const u8 = w.text(name);
    const edits = h.json.items(v);
    var i = edits.len;
    while (i > 0) {
        i -= 1;
        const e = edits[i];
        const from = offsetOf(text, h.json.int(h.json.path(e, &.{ "range", "start", "line" })) orelse 0, h.json.int(h.json.path(e, &.{ "range", "start", "character" })) orelse 0);
        const to = offsetOf(text, h.json.int(h.json.path(e, &.{ "range", "end", "line" })) orelse 0, h.json.int(h.json.path(e, &.{ "range", "end", "character" })) orelse 0);
        text = try std.mem.concat(w.a(), u8, &.{ text[0..from], h.json.str(h.json.get(e, "newText")) orelse "", text[to..] });
    }
    return text;
}

test "findent indents free and fixed form (#739)" {
    try tools.need("findent");
    const w = try h.Workspace.init(&.{ free, fixed }, .{ .init_options = "{\"formatter\": \"findent\", \"formatter_args\": [\"-i2\"]}" });
    defer w.deinit();
    try std.testing.expectEqualStrings("program p\n  x=1+2\nend program p\n", try formatted(w, "a.f90"));
    // -ifixed
    try std.testing.expectEqualStrings("      program p\n        if (.true.) then\n          x = 1\n        end if\n      end program p\n", try formatted(w, "b.f"));
    try std.testing.expectEqual(@as(usize, 0), (try w.messages()).len);
}

test "fprettify puts spaces around operators (#739)" {
    try tools.need("fprettify");
    const w = try h.Workspace.init(&.{free}, .{ .init_options = "{\"formatter\": \"fprettify\"}" });
    defer w.deinit();
    try std.testing.expectEqualStrings("program p\n   x = 1 + 2\nend program p\n", try formatted(w, "a.f90"));
    try std.testing.expectEqual(@as(usize, 0), (try w.messages()).len);
}

test "fortitude: its problem on its line, with its fix (#739)" {
    try tools.need("fortitude");
    const w = try h.Workspace.init(&.{free}, .{ .init_options = "{\"fortitude\": true}" });
    defer w.deinit();
    try w.open("a.f90", "fortran");
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", "\"source\":\"fortitude\"", 60)) orelse return error.NotLinted;
    // C001, implicit typing, on the program statement
    try std.testing.expect(std.mem.find(u8, sent, "\"code\":\"C001\"") != null);
    const actions = try w.codeActions("a.f90", 0);
    var fix = false;
    for (actions) |act| fix = fix or std.mem.find(u8, act.new_text, "implicit none") != null;
    try std.testing.expect(fix);
}

const gfortran = tools.logging("gfortran", "a.f90:2:3: Error: said by the stand-in gfortran", true);
const fypp_file = h.File{ .name = "a.fypp", .text = "program a\n#:if N == 1\n  x = 1\n#:endif\nend program a\n" };

/// What zfls publishes for a.fypp through the real fypp and a stand-in
/// gfortran, with `args` for fypp; once the stand-in has run on b.f90,
/// opened after it
fn fyppDiagnostics(comptime args: []const u8) !?[]const u8 {
    const b = h.File{ .name = "b.f90", .text = "program b\nend program b\n" };
    const w = try h.Workspace.init(&.{ fypp_file, b, gfortran }, .{ .init_options = "{\"compiler_diagnostics\": \"gfortran\", \"compiler_path\": \"" ++ gfortran.name ++ "\", \"compiler_fypp\": \"fypp\", \"compiler_fypp_args\": " ++ args ++ "}" });
    defer w.deinit();
    try tools.makeExecutable(w, &.{gfortran});
    try w.open("a.fypp", "fortran");
    try w.open("b.f90", "fortran");
    if ((try tools.waitForRuns(w, "gfortran", "b.f90", 1, 60)).len == 0) return error.NotChecked;
    const sent = (try w.waitForSent("textDocument/publishDiagnostics", "\"source\":\"fypp\"", 0)) orelse return null;
    return try std.testing.allocator.dupe(u8, sent);
}

test "fypp: its error on its line, none once compiler_fypp_args defines the name (#739)" {
    try tools.need("fypp");
    const failed = (try fyppDiagnostics("[]")) orelse return error.NoFyppDiagnostics;
    defer std.testing.allocator.free(failed);
    try std.testing.expect(std.mem.find(u8, failed, "exception occurred when evaluating") != null);
    try std.testing.expect(std.mem.find(u8, failed, "\"start\":{\"line\":1") != null);
    if (try fyppDiagnostics("[\"-DN=1\"]")) |d| {
        defer std.testing.allocator.free(d);
        std.debug.print("\nfypp failed with -DN=1: {s}\n", .{d});
        return error.FyppFailed;
    }
}
