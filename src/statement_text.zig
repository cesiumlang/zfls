//! The text of a statement's first line, for the checks that read statements
//! line by line (cases.zig, loops.zig).

const std = @import("std");
const helpers = @import("helpers.zig");
const selection = @import("selection.zig");
const FortranFile = @import("parser.zig").FortranFile;

/// The code of the line the statement starts on, with the label field and
/// the comment cut, and its offset in the line
pub fn codeOf(file: *const FortranFile, raw: []const u8) ?struct { text: []const u8, offset: usize } {
    if (helpers.isComment(file.fixed, raw)) return null;
    var start: usize = 0;
    if (file.fixed) {
        start = @min(helpers.fixedStmtStart(raw), raw.len);
    } else {
        while (start < raw.len and (raw[start] == ' ' or raw[start] == '\t')) start += 1;
        // a numeric label
        var k = start;
        while (k < raw.len and std.ascii.isDigit(raw[k])) k += 1;
        if (k > start and k < raw.len and raw[k] == ' ') start = k + 1;
    }
    const end = selection.codeEnd(raw);
    if (start >= end) return null;
    const body = raw[start..end];
    const text = std.mem.trim(u8, body, " \t\r");
    if (text.len == 0) return null;
    return .{ .text = text, .offset = start + std.mem.findNone(u8, body, " \t\r").? };
}

pub fn startsWord(text: []const u8, word: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(text, word)) return false;
    return text.len == word.len or !(std.ascii.isAlphanumeric(text[word.len]) or text[word.len] == '_');
}

/// The statement after a construct name (`name: select case`)
pub fn afterName(text: []const u8) []const u8 {
    var i: usize = 0;
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return text;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    var j = i;
    while (j < text.len and text[j] == ' ') j += 1;
    if (j < text.len and text[j] == ':' and !(j + 1 < text.len and text[j + 1] == ':')) {
        j += 1;
        while (j < text.len and text[j] == ' ') j += 1;
        return text[j..];
    }
    return text;
}
