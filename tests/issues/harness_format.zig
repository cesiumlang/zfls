//! Formatting through the harness: a document's text with the edits of
//! `textDocument/formatting` made, for the tests of the formatters
//! (real_tools.zig, own_format.zig).

const std = @import("std");
const h = @import("harness.zig");

/// The offset of a 0-based line and character in `text`
fn offsetOf(text: []const u8, line: i64, character: i64) usize {
    var at: usize = 0;
    var l: i64 = 0;
    while (l < line) : (l += 1) at = (std.mem.findScalarPos(u8, text, at, '\n') orelse return text.len) + 1;
    return @min(text.len, at + @as(usize, @intCast(character)));
}

/// `name` once formatted: its text with the edits of
/// `textDocument/formatting` made, the last first
pub fn formatted(w: *h.Workspace, name: []const u8) ![]const u8 {
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
