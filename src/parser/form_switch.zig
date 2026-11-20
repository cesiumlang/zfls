//! Part of the parser (parser.zig): LLVM Flang's `!dir$ fixed` and `!dir$
//! free`, which switch a file's source form for the lines after them. A
//! file that switches is read in free form: the lines of its fixed-form
//! parts are rewritten as free-form ones in the text zfls reads, column
//! for column (a comment's `C` or `*` becomes `!`, a continuation's column
//! 6 `&`), and a line continued by the next one gets an `&` where its code
//! ends (before a blank or a comment there, else after it: such a line is
//! one longer).

const std = @import("std");
const Allocator = std.mem.Allocator;
const fixed_columns = @import("fixed_columns.zig");
const helpers = @import("../helpers.zig");

pub const Form = enum { fixed, free };

/// The form that line `line` switches to, if it is `!dir$ fixed` or `!dir$
/// free` (in any case; in fixed form also `c` or `*` in column 1)
pub fn directive(fixed: bool, line: []const u8) ?Form {
    var rest = line;
    if (fixed and rest.len > 0 and (rest[0] == 'c' or rest[0] == 'C' or rest[0] == '*')) {
        rest = rest[1..];
    } else {
        rest = std.mem.trimStart(u8, rest, " \t");
        if (rest.len == 0 or rest[0] != '!') return null;
        rest = rest[1..];
    }
    if (!std.ascii.startsWithIgnoreCase(rest, "dir$")) return null;
    rest = std.mem.trim(u8, rest[4..], " \t\r");
    if (std.mem.findScalar(u8, rest, '!')) |i| rest = std.mem.trimEnd(u8, rest[0..i], " \t");
    if (std.ascii.eqlIgnoreCase(rest, "fixed")) return .fixed;
    if (std.ascii.eqlIgnoreCase(rest, "free")) return .free;
    return null;
}

/// The first line that is `!dir$ fixed` or `!dir$ free` in either form
pub fn first(lines: []const []const u8) ?usize {
    for (lines, 0..) |l, i| if (directive(true, l) != null) return i;
    return null;
}

/// Whether a file of form `fixed` has a directive that switches it to the
/// other form
pub fn switches(fixed: bool, lines: []const []const u8) bool {
    var form: Form = if (fixed) .fixed else .free;
    for (lines) |l| if (directive(form == .fixed, l)) |to| {
        if (to != form) return true;
        form = to;
    };
    return false;
}

/// Whether a fixed-form line is a comment: `C`, `c`, `*` or `!` in column
/// 1 (also a `D` line, with `d_lines_code` false), `!` first elsewhere than
/// in column 6, or blank
fn isFixedComment(line: []const u8, d_lines_code: bool) bool {
    if (line.len == 0) return true;
    switch (line[0]) {
        'c', 'C', '*', '!' => return true,
        'd', 'D' => return !d_lines_code,
        else => {},
    }
    const code = std.mem.findNone(u8, line, " \t\r") orelse return true;
    return line[code] == '!' and code != 5;
}

fn isFixedContinuation(line: []const u8) bool {
    return helpers.fixedContMark(line) != null;
}

/// Where a fixed-form code line's code ends: at its `!` comment (outside
/// strings), else at its end
fn codeEnd(line: []const u8) usize {
    var quote: u8 = 0;
    var i: usize = helpers.fixedContMark(line) orelse 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
        } else if (ch == '!') return i;
    }
    return line.len;
}

/// The lines of a file of form `fixed` that switches (`switches`) as free
/// form: a copy of them in one buffer (each followed by `\n`), owned by
/// `gpa`, with its lines. The columns of a fixed-form code line past
/// `columns` (`fixed_line_length`) are blanks.
pub fn asFree(gpa: Allocator, fixed: bool, d_lines_code: bool, columns: ?usize, raw: []const []const u8) !struct { text: []u8, lines: std.ArrayList([]const u8) } {
    // the form of each line, and whether its code needs an `&` appended
    const forms = try gpa.alloc(Form, raw.len);
    defer gpa.free(forms);
    var form: Form = if (fixed) .fixed else .free;
    for (raw, 0..) |l, i| {
        forms[i] = form;
        if (directive(form == .fixed, l)) |to| form = to;
    }
    const amp = try gpa.alloc(Amp, raw.len);
    defer gpa.free(amp);
    @memset(amp, .none);
    // a fixed-form code line before a continuation line
    var last_code: ?usize = null;
    for (raw, 0..) |l, i| {
        if (forms[i] != .fixed) {
            last_code = null;
            continue;
        }
        if (isFixedComment(l, d_lines_code) or (l.len > 0 and l[0] == '#')) continue;
        if (isFixedContinuation(l)) if (last_code) |c| {
            const code = fixed_columns.code(raw[c], columns);
            const end = codeEnd(code);
            amp[c] = if (end > 1 and code[end - 1] == ' ') .blank else .insert;
        };
        last_code = i;
    }
    var total: usize = 0;
    for (raw, amp) |l, x| total += l.len + 1 + @intFromBool(x == .insert);
    const text = try gpa.alloc(u8, total);
    errdefer gpa.free(text);
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    try lines.ensureTotalCapacity(gpa, raw.len);
    var at: usize = 0;
    for (raw, 0..) |l, i| {
        var n = l.len;
        const line = text[at .. at + l.len + @intFromBool(amp[i] == .insert)];
        @memcpy(line[0..l.len], l);
        if (forms[i] == .fixed) {
            if (columns) |c| if (!isFixedComment(l, d_lines_code)) fixed_columns.blank(line[0..l.len], c);
            n = fixedLine(line, l.len, amp[i], d_lines_code);
        }
        lines.appendAssumeCapacity(line[0..n]);
        text[at + n] = '\n';
        at += n + 1;
    }
    std.debug.assert(at == total);
    return .{ .text = text, .lines = lines };
}

/// Where a line continued by the next one gets its `&`: none (it is not
/// continued), in place of the blank where its code ends, or inserted there
const Amp = enum { none, blank, insert };

/// Line `line[0..len]` of fixed form rewritten as free form in place (with
/// room for one byte more when `amp` is `.insert`): its new length
fn fixedLine(line: []u8, len: usize, amp: Amp, d_lines_code: bool) usize {
    const l = line[0..len];
    if (l.len == 0) return 0;
    if (l[0] == '#') return len;
    if (isFixedComment(l, d_lines_code)) {
        if (l[0] != ' ') l[0] = '!';
        return len;
    }
    // a debug line read as code
    if (l[0] == 'd' or l[0] == 'D') l[0] = ' ';
    if (helpers.fixedContMark(l)) |s| {
        // `&` for the mark; a TAB before it (TAB-format) a blank
        l[s - 1] = '&';
        if (s != 6) l[s - 2] = ' ';
    }
    if (amp == .none) return len;
    const end = codeEnd(l);
    if (amp == .blank) {
        l[end - 1] = '&';
        return len;
    }
    @memmove(line[end + 1 .. len + 1], line[end..len]);
    line[end] = '&';
    return len + 1;
}

test "the directives that switch the form" {
    try std.testing.expectEqual(Form.fixed, directive(false, "!dir$ fixed").?);
    try std.testing.expectEqual(Form.free, directive(false, "  !DIR$ FREE ! the rest").?);
    try std.testing.expectEqual(Form.free, directive(true, "cdir$ free").?);
    try std.testing.expectEqual(Form.free, directive(true, "*DIR$ FREE").?);
    try std.testing.expect(directive(false, "cdir$ free") == null);
    try std.testing.expect(directive(false, "!dir$ freeform") == null);
    try std.testing.expect(directive(false, "!dir$ ignore_tkr a") == null);
    try std.testing.expect(directive(false, "! dir$ free") == null);
    try std.testing.expect(switches(false, &.{ "module m", "!dir$ fixed", "      end" }));
    try std.testing.expect(switches(true, &.{ "      x = 1", "!dir$ free" }));
    // to the form it is in already
    try std.testing.expect(!switches(true, &.{ "!dir$ fixed", "      x = 1" }));
    try std.testing.expect(!switches(false, &.{"x = 1"}));
    try std.testing.expectEqual(@as(?usize, 1), first(&.{ "      x = 1", "cdir$ free", "!dir$ fixed" }));
    try std.testing.expectEqual(@as(?usize, 0), first(&.{ "  !DIR$ FIXED", "x = 1" }));
    try std.testing.expect(first(&.{"x = 1"}) == null);
}

test "fixed-form lines as free form" {
    const gpa = std.testing.allocator;
    const raw = [_][]const u8{
        "module m",
        "contains",
        "!dir$ fixed",
        "      SUBROUTINE OLD(X)",
        "C     A COMMENT LINE CALL NOWHERE(Q)",
        "*     ANOTHER",
        "      X = X +",
        "     &    1.0",
        "      Y = 'A' // ! a comment",
        "c     between",
        "     1    'B'",
        "D     PRINT *, X",
        "   10 END SUBROUTINE",
        "!dir$ free",
        "end module",
    };
    const out = try asFree(gpa, false, false, null, &raw);
    defer gpa.free(out.text);
    var lines = out.lines;
    defer lines.deinit(gpa);
    const want = [_][]const u8{
        "module m",
        "contains",
        "!dir$ fixed",
        "      SUBROUTINE OLD(X)",
        "!     A COMMENT LINE CALL NOWHERE(Q)",
        "!     ANOTHER",
        "      X = X +&",
        "     &    1.0",
        "      Y = 'A' //&! a comment",
        "!     between",
        "     &    'B'",
        "!     PRINT *, X",
        "   10 END SUBROUTINE",
        "!dir$ free",
        "end module",
    };
    try std.testing.expectEqual(want.len, lines.items.len);
    for (want, lines.items) |w, got| try std.testing.expectEqualStrings(w, got);
    try std.testing.expectEqual(lines.items.len, std.mem.count(u8, out.text, "\n"));
    // a fixed-form file that switches to free form; debug lines as code
    const raw2 = [_][]const u8{ "      X = 1", "D     X = 2", "!dir$ free", "x = 3 + &", "  4" };
    const out2 = try asFree(gpa, true, true, null, &raw2);
    defer gpa.free(out2.text);
    var lines2 = out2.lines;
    defer lines2.deinit(gpa);
    try std.testing.expectEqualStrings("      X = 2", lines2.items[1]);
    try std.testing.expectEqualStrings("x = 3 + &", lines2.items[3]);
    try std.testing.expectEqualStrings("  4", lines2.items[4]);
    // the columns past fixed_line_length, of the fixed-form lines only
    const raw3 = [_][]const u8{ "      X = 1 + Y", "     &    + Z", "!dir$ free", "x = 3 + long_free_line" };
    const out3 = try asFree(gpa, true, false, 13, &raw3);
    defer gpa.free(out3.text);
    var lines3 = out3.lines;
    defer lines3.deinit(gpa);
    try std.testing.expectEqualStrings("      X = 1 +  &", lines3.items[0]);
    try std.testing.expectEqualStrings("     &    + Z", lines3.items[1]);
    try std.testing.expectEqualStrings("x = 3 + long_free_line", lines3.items[3]);
}

test "a file's lines after an edit of its directive" {
    const FortranFile = @import("../parser.zig").FortranFile;
    const f = try FortranFile.create(std.testing.allocator, "/w/a.f", null);
    defer f.destroy();
    // a fixed-form file by its first lines, though its free-form part is not
    _ = try f.setText("      SUBROUTINE OLD\nC     A COMMENT\n      END\n!dir$ free\nsubroutine new()\nend subroutine\n");
    try std.testing.expect(f.declared_fixed and f.form_switched and !f.fixed);
    try std.testing.expectEqualStrings("!     A COMMENT", f.getLine(1, false).?);
    // the editor's lines as they are
    try std.testing.expectEqualStrings("C     A COMMENT", f.editLines()[1]);
    // the directive edited away: read as it is written, parsed again
    try std.testing.expect(try f.applyChange(.{ .text = "!dir$ ivdep", .range = .{ .sl = 3, .sc = 0, .el = 3, .ec = 10 } }));
    try std.testing.expect(f.declared_fixed and !f.form_switched and f.fixed);
    try std.testing.expectEqualStrings("C     A COMMENT", f.getLine(1, false).?);
    try std.testing.expect(try f.applyChange(.{ .text = "!dir$ free", .range = .{ .sl = 3, .sc = 0, .el = 3, .ec = 11 } }));
    try std.testing.expect(f.form_switched and !f.fixed);
    try std.testing.expectEqualStrings("!     A COMMENT", f.getLine(1, false).?);
}
