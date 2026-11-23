//! Words that look like an intrinsic procedure but are not one where they
//! stand: the operators `.or.` and `.and.`, a type keyword that starts a
//! declaration (`logical r`), the `precision` of `double precision` (#845).

const std = @import("std");

const dot_operators = [_][]const u8{ "and", "or", "not", "eqv", "neqv", "xor", "eq", "ne", "lt", "le", "gt", "ge" };
const type_words = [_][]const u8{ "integer", "real", "complex", "logical", "character", "byte", "double" };
// words a type keyword follows in a statement that starts with a prefix
const prefix_words = [_][]const u8{ "pure", "impure", "elemental", "recursive", "non_recursive", "simple", "module", "implicit" };

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn inList(list: []const []const u8, word: []const u8) bool {
    for (list) |k| if (std.ascii.eqlIgnoreCase(k, word)) return true;
    return false;
}

/// Whether the word at byte `col` of `line` is no intrinsic procedure's
/// name: `prefix` is the statement's text (continuation lines included) up
/// to `col`
pub fn isKeywordOrOperator(line: []const u8, prefix: []const u8, col: usize) bool {
    if (col > line.len) return false;
    var s = col;
    while (s > 0 and isWordChar(line[s - 1])) s -= 1;
    var e = col;
    while (e < line.len and isWordChar(line[e])) e += 1;
    if (s == e) return false;
    const word = line[s..e];
    if (s > 0 and line[s - 1] == '.' and e < line.len and line[e] == '.' and inList(&dot_operators, word)) return true;
    // the text of the statement before the word
    const before = std.mem.trimEnd(u8, prefix[0..prefix.len -| (col - s)], " \t");
    if (std.ascii.eqlIgnoreCase(word, "precision")) return endsWithWord(before, "double");
    if (!inList(&type_words, word)) return false;
    var start = std.mem.trimStart(u8, before, " \t");
    // a statement label
    while (start.len > 0 and std.ascii.isDigit(start[0])) start = std.mem.trimStart(u8, start[1..], " \t");
    if (start.len == 0) return true;
    for (prefix_words) |p| if (endsWithWord(start, p)) return true;
    return isTypeSpecPosition(start);
}

// a type-spec in parentheses: allocate(real :: x), type is (real), procedure(real) :: p
fn isTypeSpecPosition(start: []const u8) bool {
    if (!std.mem.endsWith(u8, start, "(")) return false;
    const head = std.mem.trimEnd(u8, start[0 .. start.len - 1], " \t");
    if (endsWithWord(head, "allocate") or endsWithWord(head, "procedure")) return true;
    if (!endsWithWord(head, "is")) return false;
    return std.ascii.startsWithIgnoreCase(start, "type") or std.ascii.startsWithIgnoreCase(start, "class");
}

fn endsWithWord(text: []const u8, word: []const u8) bool {
    if (text.len < word.len or !std.ascii.eqlIgnoreCase(text[text.len - word.len ..], word)) return false;
    return text.len == word.len or !isWordChar(text[text.len - word.len - 1]);
}

test "operators and type keywords are not intrinsic names" {
    // the prefix is the statement up to the cursor, as the line is read
    const cases = [_]struct { line: []const u8, col: usize, want: bool }{
        .{ .line = "  r = a .or. b", .col = 10, .want = true },
        .{ .line = "  r = a .and. b", .col = 11, .want = true },
        .{ .line = "  logical r", .col = 4, .want = true },
        .{ .line = "  double precision function f(x)", .col = 12, .want = true },
        .{ .line = "  pure real function f(x)", .col = 8, .want = true },
        .{ .line = "  allocate(real :: x)", .col = 12, .want = true },
        .{ .line = "  allocate(character(len=3) :: x)", .col = 12, .want = true },
        .{ .line = "  type is (real)", .col = 12, .want = true },
        .{ .line = "  class is (integer(4))", .col = 14, .want = true },
        .{ .line = "  procedure(real) :: p", .col = 13, .want = true },
        .{ .line = "  r = is(real(x))", .col = 11, .want = false },
        .{ .line = "  r = logical(r)", .col = 8, .want = false },
        .{ .line = "  r = precision(x)", .col = 8, .want = false },
        .{ .line = "  i = real(x)", .col = 8, .want = false },
    };
    for (cases) |c| try std.testing.expectEqual(c.want, isKeywordOrOperator(c.line, c.line[0..c.col], c.col));
}
