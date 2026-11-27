//! Documentation comments (`!>`, `!<`, `!!`, and plain comments with
//! `hover_plain_comments`): read and given to the objects they document.
//! Part of `Parser` (parse.zig): each function takes it as `p`.

const std = @import("std");
const str = @import("../str.zig");
const helpers = @import("../helpers.zig");
const patterns = @import("../patterns.zig");
const plain_docs = @import("plain_docs.zig");
const Parser = @import("parse.zig").Parser;

fn R() *const patterns.Patterns {
    return patterns.get();
}

pub fn setSingleLineDocstring(p: *Parser, line: []const u8) !void {
    p.docs = .empty;
    const mark = helpers.docMark(false, line) orelse return;
    const doc = str.strip(line[mark + 1 ..]);
    if (doc.len > 0) try p.docs.append(p.scratch.allocator(), try p.scratch.allocator().dupe(u8, doc));
}

pub fn formatDocs(p: *Parser, docs: []const []const u8) ![]const u8 {
    const a = p.scratch.allocator();
    if (docs.len == 1) return docs[0];
    var docstr: std.ArrayList(u8) = .empty;
    var has_args = true;
    var idx_args: isize = -1;
    for (docs) |line| {
        if (std.mem.startsWith(u8, line, "@brief")) {
            try docstr.appendSlice(a, str.strip(try str.replaceFirst(a, line, "@brief", "")));
            try docstr.append(a, '\n');
        } else if (std.mem.startsWith(u8, line, "@param")) {
            if (has_args) {
                try docstr.appendSlice(a, "\n**Parameters:**  \n");
                has_args = false;
                idx_args = @intCast(docstr.items.len);
            }
            try docstr.appendSlice(a, try R().DOC_PARAM.sub(a, "  \\n`\\1` - ", try std.mem.concat(a, u8, &.{ line, " " })));
        } else if (std.mem.startsWith(u8, line, "@return")) {
            try docstr.appendSlice(a, "\n**Returns:**  \n");
            try docstr.appendSlice(a, str.strip(try str.replaceFirst(a, line, "@return", "")));
            try docstr.append(a, '\n');
        } else {
            try docstr.appendSlice(a, str.strip(line));
            try docstr.append(a, '\n');
        }
    }
    if (idx_args > 0) {
        const ia: usize = @intCast(idx_args);
        const head = str.slice(docstr.items, 0, idx_args - 3);
        const tail = try str.replaceFirst(a, docstr.items[ia..], "  \n ", "");
        return std.mem.concat(a, u8, &.{ head, tail });
    }
    return docstr.items;
}

pub fn addLineComment(p: *Parser) !void {
    if (p.docs.items.len > 0) {
        const fd = try p.formatDocs(p.docs.items);
        try p.file_ast.addDoc(fd, false);
        p.dbg("{s} !!! Doc string - Line:{d}", .{ fd, p.cur_line });
        p.docs.clearRetainingCapacity();
    }
}

/// A block of plain comment lines (`hover_plain_comments`) from line
/// `ln` (1-based): noted as documentation; returns the index of the
/// line after it, or null when the line is no plain comment
pub fn parsePlainDocs(p: *Parser, line: []const u8, ln: usize) !?usize {
    if (plain_docs.lineText(p.file.fixed, line) == null) return null;
    try p.addLineComment();
    const sa = p.scratch.allocator();
    const blk = try plain_docs.readBlock(sa, p.file, ln - 1);
    if (blk.lines.len > 0) try p.plain.addBlock(sa, p.file, try p.formatDocs(blk.lines), ln, blk.next, p.file_ast.last_obj);
    return blk.next;
}

/// Parse documentation strings; returns the new line number, or null when the line is no documentation
pub fn parseDocs(p: *Parser, line: []const u8, ln: usize) !?usize {
    const fixed = p.file.fixed;
    if (!helpers.isComment(fixed, line)) {
        try p.addLineComment();
        return null;
    }
    const mark = helpers.docMark(fixed, line) orelse {
        try p.addLineComment();
        return null;
    };
    const sa = p.scratch.allocator();
    // get_docstring
    try p.docs.append(sa, str.strip(line[mark + 1 ..]));
    const predocmark = line[mark] == '>';
    const n = p.file.nLines();
    // a block that ends the file ends at its end, read once (#965)
    var new_ln = @max(ln, n);
    if (ln < n) {
        var i = ln;
        while (i < n) : (i += 1) {
            const next_line = p.file.getLine(i, true) orelse "";
            const next_mark = helpers.docMark(fixed, next_line) orelse {
                new_ln = i;
                break;
            };
            try p.docs.append(sa, str.strip(next_line[next_mark + 1 ..]));
        }
    }
    var total: usize = 0;
    for (p.docs.items) |d| total += d.len;
    if (total > 0) try p.file_ast.addDoc(try p.formatDocs(p.docs.items), predocmark);
    for (p.docs.items, 0..) |d, k| p.dbg("{s} !!! Doc string - Line:{d}", .{ d, ln + k });
    p.docs.clearRetainingCapacity();
    return new_ln;
}
