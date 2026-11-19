//! Helpers for the tests of code actions: the text an action makes of a
//! file, and whether gfortran accepts it.

const std = @import("std");
const h = @import("harness.zig");
const json = h.json;
const Value = json.Value;

const io = std.testing.io;

/// The text of file `name` (as written) after the edits that the code
/// action titled `title`, asked for on 0-based lines `first`..`last` with
/// the kinds `only` (all when null), makes in it (ASCII text); null when
/// there is no such action
pub fn applyAction(w: *h.Workspace, name: []const u8, first: i64, last: i64, only: ?[]const []const u8, title: []const u8) !?[]const u8 {
    const a = w.arena.allocator();
    const uri = try w.uri(name);
    const v = try w.server.dispatchPublic(a, "textDocument/codeAction", try json.from(a, .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = .{ .line = first, .character = 0 }, .end = .{ .line = last, .character = 0 } },
        .context = .{ .only = only },
    }));
    const act = for (json.items(v)) |act| {
        if (std.mem.eql(u8, json.str(json.get(act, "title")) orelse "", title)) break act;
    } else return null;
    const edits = json.get(json.path(act, &.{ "edit", "changes" }) orelse .null, uri) orelse .null;
    return try apply(a, w.text(name), json.items(edits));
}

/// Why the code action titled `title`, asked for on 0-based lines
/// `first`..`last` with the kinds `only`, cannot be taken (its `disabled`
/// reason); null when there is no such action or it can be taken
pub fn disabledReason(w: *h.Workspace, name: []const u8, first: i64, last: i64, only: ?[]const []const u8, title: []const u8) !?[]const u8 {
    const a = w.arena.allocator();
    const v = try w.server.dispatchPublic(a, "textDocument/codeAction", try json.from(a, .{
        .textDocument = .{ .uri = try w.uri(name) },
        .range = .{ .start = .{ .line = first, .character = 0 }, .end = .{ .line = last, .character = 0 } },
        .context = .{ .only = only },
    }));
    for (json.items(v)) |act| {
        if (!std.mem.eql(u8, json.str(json.get(act, "title")) orelse "", title)) continue;
        if (json.str(json.path(act, &.{ "disabled", "reason" }) orelse .null)) |r| return r;
    }
    return null;
}

/// `text` with the LSP text `edits` made (ASCII text)
pub fn apply(a: std.mem.Allocator, text: []const u8, edits: []const Value) ![]const u8 {
    var starts: std.ArrayList(usize) = .empty;
    try starts.append(a, 0);
    for (text, 0..) |ch, i| if (ch == '\n') try starts.append(a, i + 1);
    const Span = struct { from: usize, to: usize, new: []const u8 };
    var spans: std.ArrayList(Span) = .empty;
    for (edits) |e| {
        const r = json.get(e, "range") orelse .null;
        try spans.append(a, .{
            .from = offset(starts.items, text.len, json.get(r, "start") orelse .null),
            .to = offset(starts.items, text.len, json.get(r, "end") orelse .null),
            .new = json.str(json.get(e, "newText")) orelse "",
        });
    }
    std.mem.sort(Span, spans.items, {}, struct {
        fn lt(_: void, x: Span, y: Span) bool {
            return x.from < y.from;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (spans.items) |s| {
        if (s.from < at or s.to < s.from) return h.unmet("overlapping edits", .{});
        try out.appendSlice(a, text[at..s.from]);
        try out.appendSlice(a, s.new);
        at = s.to;
    }
    try out.appendSlice(a, text[at..]);
    return out.items;
}

fn offset(starts: []const usize, len: usize, p: Value) usize {
    const l: usize = @intCast(json.int(json.get(p, "line")) orelse 0);
    const c: usize = @intCast(json.int(json.get(p, "character")) orelse 0);
    return if (l < starts.len) @min(starts[l] + c, len) else len;
}

var compiled: usize = 0;

/// That gfortran, when it is on the PATH, finds no error in `files`
/// (compiled in this order with `-fsyntax-only`, in a new directory of the
/// workspace)
pub fn expectCompiles(w: *h.Workspace, files: []const h.File) !void {
    const a = w.arena.allocator();
    compiled += 1;
    const dir = try a.print("gfortran-{d}", .{compiled});
    try w.tmp.dir.createDirPath(io, dir);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "gfortran", "-fsyntax-only" });
    for (files) |f| {
        try w.tmp.dir.writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ dir, f.name }), .data = f.text });
        try argv.append(a, f.name);
    }
    const r = std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = try w.path(dir) } }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    if (!r.term.success()) return h.unmet("gfortran rejects it:\n{s}", .{r.stderr});
}
