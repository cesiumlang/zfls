//! Plain `!` comments as documentation (#263, `hover_plain_comments`):
//! for a declaration that has no `!>`, `!<` or `!!` documentation, the
//! block of comment lines directly above it (no blank line between), a
//! comment at the end of its line, or for a procedure a block right under
//! its header line. Directives (`!$omp`, `!dir$`) are no comments here;
//! ruler lines (`!-----`) are left out of the text.
//! Part of `Parser` (parse.zig): it collects what it reads in `PlainDocs`
//! and gives the documentation to the declarations at the end of the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const objects = @import("../objects.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = @import("../parser.zig").FortranFile;

pub const PlainDocs = struct {
    /// The documentation of the declarations that start on a line (1-based):
    /// a block of comment lines directly above it
    above: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,
    /// The documentation of the declarations that start on a line (1-based):
    /// a comment at the end of the statement
    trailing: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,
    /// Procedures and the block right under their header line
    header: std.ArrayList(struct { obj: *Obj, doc: []const u8 }) = .empty,
    /// The first and last line (1-based) of the last statement read
    stmt_start: usize = 0,
    stmt_end: usize = 0,

    /// Notes the documentation of block `doc` that starts on line `first`
    /// (1-based) and is followed by line index `next` (0-based); `last_obj`
    /// is the object the parser made last
    pub fn addBlock(pd: *PlainDocs, a: Allocator, file: *FortranFile, doc: []const u8, first: usize, next: usize, last_obj: ?*Obj) !void {
        // the procedure, or the result variable its header made last
        const proc = if (last_obj) |o| (if (o.kind.isSubroutine()) o else o.parent) else null;
        if (proc) |o| if (o.kind.isSubroutine() and o.sline == pd.stmt_start and pd.stmt_end + 1 == first) {
            try pd.header.append(a, .{ .obj = o, .doc = doc });
            return;
        };
        const after = file.getLine(next, true) orelse return;
        if (str.strip(after).len == 0) return;
        try pd.above.put(a, next + 1, doc);
    }

    /// Gives the documentation noted to the declarations that have none
    pub fn apply(pd: *const PlainDocs, ast: *Ast) !void {
        if (pd.above.count() == 0 and pd.trailing.count() == 0 and pd.header.items.len == 0) return;
        for ([_][]const *Obj{ ast.scope_list.items, ast.variable_list.items }) |list| for (list) |o| {
            if (o.doc_str != null or !documented(o)) continue;
            const doc = pd.trailing.get(o.sline) orelse pd.above.get(o.sline) orelse continue;
            o.addDoc(try ast.allocator().dupe(u8, doc));
        };
        for (pd.header.items) |h| if (h.obj.doc_str == null) h.obj.addDoc(try ast.allocator().dupe(u8, h.doc));
    }
};

/// Whether objects of the kind of `o` take documentation from a comment:
/// program units, procedures, types, interfaces and variables, not
/// constructs
fn documented(o: *const Obj) bool {
    return switch (o.kind) {
        .module, .submodule, .program, .subroutine, .function, .type, .interface, .variable, .method => true,
        else => false,
    };
}

/// The text of comment line `line` when it is a plain comment, `! text`;
/// "" for an empty comment or a ruler (`!-----`); null for a line that is
/// no plain comment: code, a blank line, a documentation comment (`!>`),
/// a directive (`!$omp`, `!dir$`) or, in fixed form, a debug line (`D`)
pub fn lineText(fixed: bool, line: []const u8) ?[]const u8 {
    if (!helpers.isComment(fixed, line) or helpers.docMark(fixed, line) != null) return null;
    if (fixed and (line[0] == 'd' or line[0] == 'D')) return null;
    const start = if (fixed and line[0] != ' ' and line[0] != '!') 1 else (std.mem.findScalar(u8, line, '!') orelse return null) + 1;
    return commentText(line[start..]);
}

/// The text of a comment at the end of a statement, from its `!`, when it
/// is a plain comment with text; null for a documentation comment (`!<`),
/// a directive, a ruler or an empty one
pub fn trailingText(comment: []const u8) ?[]const u8 {
    if (comment.len == 0 or comment[0] != '!') return null;
    if (comment.len > 1 and std.mem.findScalar(u8, "<>!", comment[1]) != null) return null;
    const t = commentText(comment[1..]) orelse return null;
    return if (t.len > 0) t else null;
}

/// The text after a comment's marker: null for a directive, "" for a ruler
fn commentText(rest: []const u8) ?[]const u8 {
    if (rest.len > 0 and rest[0] == '$') return null;
    for ([_][]const u8{ "dir$", "dec$", "gcc$" }) |d| if (std.ascii.startsWithIgnoreCase(rest, d)) return null;
    const t = str.strip(rest);
    for (t) |c| {
        if (std.ascii.isAlphanumeric(c) or c > 127) return t;
    } else return "";
}

/// The lines of the block of plain comment lines from line index `first`
/// (0-based), with empty ones and rulers as "" between paragraphs, and the
/// index of the line after it
pub fn readBlock(a: Allocator, file: *FortranFile, first: usize) !struct { lines: []const []const u8, next: usize } {
    var lines: std.ArrayList([]const u8) = .empty;
    var i = first;
    while (file.getLine(i, true)) |line| : (i += 1) {
        const t = lineText(file.fixed, line) orelse break;
        if (t.len == 0 and (lines.items.len == 0 or lines.items[lines.items.len - 1].len == 0)) continue;
        try lines.append(a, t);
    }
    while (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    return .{ .lines = lines.items, .next = i };
}

test lineText {
    const t = std.testing;
    try t.expectEqualStrings("a b", lineText(false, "   ! a b").?);
    try t.expectEqualStrings("", lineText(false, "!-----------").?);
    try t.expectEqualStrings("", lineText(false, "!").?);
    try t.expect(lineText(false, "!> doc") == null);
    try t.expect(lineText(false, "!$omp parallel") == null);
    try t.expect(lineText(false, "!DIR$ ATTRIBUTES") == null);
    try t.expect(lineText(false, "x = 1 ! not a comment line") == null);
    try t.expect(lineText(false, "") == null);
    try t.expectEqualStrings("fixed", lineText(true, "C     fixed").?);
    try t.expectEqualStrings("star", lineText(true, "* star").?);
    try t.expect(lineText(true, "D     print *, x") == null);
    try t.expect(lineText(true, "C$OMP PARALLEL") == null);
    try t.expectEqualStrings("x", trailingText("! x").?);
    try t.expect(trailingText("!< x") == null);
    try t.expect(trailingText("!=====") == null);
    try t.expect(trailingText("!$ omp") == null);
}
