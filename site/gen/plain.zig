//! Markdown text as plain text on one line: links are their words, emphasis
//! marks are gone.

const std = @import("std");

/// `[words](url)` becomes `words`; `**` and `__` are
/// dropped; line ends and runs of spaces become one space. Code spans keep
/// their backticks. Allocated from `arena`.
pub fn text(arena: std.mem.Allocator, markdown: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_code = false;
    while (i < markdown.len) {
        const c = markdown[i];
        if (c == '`') in_code = !in_code;
        if (!in_code) {
            if (c == '[') {
                if (linkEnd(markdown[i..])) |link| {
                    try out.appendSlice(arena, try text(arena, markdown[i + 1 .. i + link.words_end]));
                    i += link.end;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, markdown[i..], "**") or std.mem.startsWith(u8, markdown[i..], "__")) {
                i += 2;
                continue;
            }
        }
        if (c == '\n' or c == '\t') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(arena, ' ');
        } else if (c == ' ' and out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
            // a run of spaces is one
        } else {
            try out.append(arena, c);
        }
        i += 1;
    }
    return std.mem.trim(u8, out.items, " ");
}

const Link = struct { words_end: usize, end: usize };

// `[words](url)` at the start of `s`: where the words end, and the whole link
fn linkEnd(s: []const u8) ?Link {
    const close = std.mem.findScalar(u8, s, ']') orelse return null;
    if (close + 1 >= s.len or s[close + 1] != '(') return null;
    const paren = std.mem.findScalar(u8, s[close + 2 ..], ')') orelse return null;
    return .{ .words_end = close, .end = close + 2 + paren + 1 };
}
