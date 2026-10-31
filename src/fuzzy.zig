//! Fuzzy matching of symbol names (hansec #195): a query matches a name
//! whose characters it gives in order (`tar` and `thisar` both match
//! `this_amazing_routine`), ignoring case and the underscores of the query.

const std = @import("std");

/// How well `query` matches `name`, higher is better; null when it does
/// not. Characters matched at the start of the name or of one of its words
/// (after an underscore) count most, then consecutive ones.
pub fn score(name: []const u8, query: []const u8) ?u32 {
    var s: u32 = 0;
    var i: usize = 0;
    var prev_matched = false;
    for (query) |qc| {
        if (qc == '_') continue;
        const q = std.ascii.toLower(qc);
        while (i < name.len and std.ascii.toLower(name[i]) != q) : (i += 1) prev_matched = false;
        if (i == name.len) return null;
        if (i == 0 or name[i - 1] == '_') {
            s += 10;
        } else if (prev_matched) {
            s += 5;
        } else {
            s += 1;
        }
        prev_matched = true;
        i += 1;
    }
    return s;
}

test "subsequences match, the start of words counting most" {
    const name = "this_amazing_routine";
    try std.testing.expect(score(name, "thisamazingroutine") != null);
    try std.testing.expect(score(name, "tar") != null);
    try std.testing.expect(score(name, "THISAR") != null);
    try std.testing.expect(score(name, "this_ar") != null);
    try std.testing.expect(score(name, "rat") == null);
    try std.testing.expect(score(name, "tar").? > score(name, "tsg").?);
    try std.testing.expectEqual(@as(?u32, 0), score(name, ""));
}
