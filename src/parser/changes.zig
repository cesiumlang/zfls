//! Changes of the editor applied to a file's text (`textDocument/didChange`),
//! and whether one needs the file parsed again.
//! Part of `FortranFile` (parser.zig): each function takes it as `self`.

const std = @import("std");
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const parser = @import("../parser.zig");
const FortranFile = parser.FortranFile;
const Change = parser.Change;
const splitLines = parser.splitLines;
const getFortranDefinition = parser.getFortranDefinition;

fn R() *const patterns.Patterns {
    return patterns.get();
}

/// Apply a change to the file; returns whether a reparse is required
pub fn applyChange(self: *FortranFile, change: Change) !bool {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    self.hash = null;
    const text = change.text;
    const text_split: []const []const u8 = if (text.len == 0) &.{""} else try splitLines(a, text);
    const rng = change.range orelse {
        try self.setContents(text_split, true);
        return true;
    };
    const n = self.nLines();
    const current = self.editLines();
    if (rng.sl == n) {
        var all: std.ArrayList([]const u8) = .empty;
        for (current) |l| try all.append(a, l);
        try all.appendSlice(a, text_split);
        try self.setContents(all.items, true);
        return true;
    }
    if (rng.sl > n or rng.el >= n + 1) return error.InvalidRange;
    const start_line = current[rng.sl];
    const end_line = if (rng.el < n) current[rng.el] else "";
    const start_col = @min(str.utf16ToByte(start_line, rng.sc), start_line.len);
    const end_col = @min(str.utf16ToByte(end_line, rng.ec), end_line.len);

    // Single line edit
    if (rng.sl == rng.el and text_split.len == 1) {
        const prev = current[rng.sl];
        const new_line = try std.mem.concat(a, u8, &.{ prev[0..start_col], text, prev[@max(end_col, start_col)..] });
        const replaced = try a.dupe([]const u8, current);
        replaced[rng.sl] = new_line;
        // The buffer is rebuilt, which the preprocessed lines that are
        // the raw lines themselves must follow; the others are in pp_arena
        const old_pp = self.pp_lines;
        const old_skips = self.pp_skips;
        var raw: []bool = &.{};
        if (old_pp) |pl| {
            raw = try a.alloc(bool, pl.len);
            const lo = @intFromPtr(self.text.ptr);
            const hi = lo + self.text.len;
            for (pl, raw) |l, *r| r.* = @intFromPtr(l.ptr) >= lo and @intFromPtr(l.ptr) < hi;
        }
        try self.setContents(replaced, false);
        if (old_pp) |pl| {
            for (pl, raw, 0..) |*l, r, i| {
                if (r) l.* = self.lines.items[i];
            }
            pl[rng.sl] = try self.pp_arena.allocator().dupe(u8, self.lines.items[rng.sl]);
            self.pp_lines = pl;
            self.pp_skips = old_skips;
        }
        return checkChangeReparse(self, @intCast(rng.sl));
    }

    var new_contents: std.ArrayList([]const u8) = .empty;
    for (current, 0..) |line, i| {
        if (i < rng.sl or i > rng.el) {
            try new_contents.append(a, line);
            continue;
        }
        if (i == rng.sl) {
            for (text_split, 0..) |cl, j| {
                if (j == 0) {
                    try new_contents.append(a, try std.mem.concat(a, u8, &.{ line[0..start_col], cl }));
                } else {
                    try new_contents.append(a, cl);
                }
            }
        }
        if (i == rng.el) {
            const last = new_contents.items.len - 1;
            new_contents.items[last] = try std.mem.concat(a, u8, &.{ new_contents.items[last], line[end_col..] });
        }
    }
    try self.setContents(new_contents.items, true);
    return true;
}

fn checkChangeReparse(self: *FortranFile, line_no: usize) !bool {
    if (line_no >= self.nLines()) return true;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cl = try self.getCodeLine(a, line_no, false, true, false, false);
    const curr_line = cl.curr.?;
    if (helpers.isComment(self.fixed, curr_line)) return false;
    var full_line: []const u8 = try std.mem.concat(a, u8, &.{ try std.mem.concat(a, u8, cl.pre), curr_line });
    const lr = try helpers.stripLineLabel(a, full_line);
    full_line = lr.line;
    if (lr.label != null) return true;
    const line_stripped = try helpers.stripStrings(a, full_line, true);
    if (std.mem.findScalar(u8, line_stripped, ';') != null) return true;
    const line_no_comment = if (std.mem.findScalar(u8, line_stripped, '!')) |ci| full_line[0..ci] else full_line;
    if (R().END_WORD.match(line_no_comment) != null) return true;
    if (R().IMPLICIT.match(line_no_comment) != null) return true;
    if (R().CONTAINS.match(line_no_comment) != null) return true;
    if (R().NON_DEF.match(line_no_comment) != null) return false;
    return (try getFortranDefinition(a, line_no_comment)) != null;
}
