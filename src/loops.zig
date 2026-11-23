//! EXIT and CYCLE with no construct name outside a DO construct (#850).
//! gfortran, Flang and ifx all report them. DO constructs are counted
//! statement by statement, label-terminated ones (`do 10 i = 1, n`) closed
//! by their label; the file is left alone when anything breaks the count
//! (an END DO with no DO, a DO still open at the end, `;`, an INCLUDE, lines
//! a preprocessor conditional leaves out). A named EXIT may leave any
//! construct and is not checked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const selection = @import("selection.zig");
const constructs = @import("constructs.zig");
const labels = @import("labels.zig");
const statement_text = @import("statement_text.zig");
const inactive_lines = @import("inactive.zig");
const typing = @import("argcheck/typing.zig");
const objects = @import("objects.zig");
const FortranFile = @import("parser.zig").FortranFile;

const startsWord = statement_text.startsWord;

pub const Problem = struct { line: usize, start: usize, end: usize, message: []const u8, is_exit: bool };

/// The statement after the condition of a logical IF, else `text`
fn afterCondition(text: []const u8) []const u8 {
    if (!startsWord(text, "if")) return text;
    const rest = std.mem.trimStart(u8, text[2..], " ");
    if (rest.len == 0 or rest[0] != '(') return text;
    const close = typing.matching(rest, 0) orelse return text;
    const inner = std.mem.trimStart(u8, rest[close + 1 ..], " ");
    // `if (...) then`, the arithmetic IF, and an empty rest are no logical IF
    if (inner.len == 0 or std.ascii.isDigit(inner[0]) or startsWord(inner, "then")) return text;
    return inner;
}

pub fn check(a: Allocator, file: *const FortranFile, ast: *objects.Ast) ![]const Problem {
    var out: std.ArrayList(Problem) = .empty;
    const skipped = try inactive_lines.of(a, file);
    if (skipped.any or ast.include_statements.items.len > 0) return out.items;
    // the labels that close the DO constructs open (null: closed by END DO)
    var open: std.ArrayList(?u32) = .empty;
    const n = file.nLines();
    var ln: usize = 0;
    while (ln < n) {
        const st = selection.statementLines(file, ln);
        defer ln = st.last + 1;
        const raw = file.getLine(ln, false) orelse continue;
        const c = statement_text.codeOf(file, raw) orelse continue;
        const code = try helpers.stripStrings(a, c.text, true);
        if (std.mem.findScalar(u8, code, ';') != null) return &.{};
        const label: ?u32 = if ((try constructs.labelsOf(a, file, ln)).def) |d| labels.labelValue(file, d) else null;
        const text = afterCondition(statement_text.afterName(code));
        const lead = c.offset + (code.len - text.len);
        if (startsWord(text, "do")) {
            const rest = std.mem.trimStart(u8, text[2..], " ");
            // an assignment to a variable named `do`
            if (rest.len > 0 and (rest[0] == '=' or rest[0] == '(' or rest[0] == '%')) continue;
            var k: usize = 0;
            while (k < rest.len and std.ascii.isDigit(rest[k])) k += 1;
            const closes: ?u32 = if (k > 0) std.fmt.parseInt(u32, rest[0..k], 10) catch return &.{} else null;
            try open.append(a, closes);
        } else if (file.fixed and std.ascii.startsWithIgnoreCase(text, "do") and !startsWord(text, "double") and !std.ascii.startsWithIgnoreCase(text, "doubleprecision")) {
            // `do10i=1,5`, `dowhile (x)`: a DO the blanks do not show
            return &.{};
        } else if (startsWord(text, "enddo") or (startsWord(text, "end") and startsWord(std.mem.trimStart(u8, text[3..], " "), "do"))) {
            if (open.items.len == 0) return &.{};
            const top = open.items[open.items.len - 1];
            if (top == null or (label != null and top.? == label.?)) {
                _ = open.pop();
            } else return &.{};
            continue;
        } else for ([_][]const u8{ "exit", "cycle" }) |word| if (startsWord(text, word)) {
            const rest = std.mem.trimStart(u8, text[word.len..], " ");
            // a named one, or `exit = 1`
            if (rest.len > 0) continue;
            if (open.items.len > 0) continue;
            const is_exit = word[0] == 'e';
            try out.append(a, .{
                .line = ln,
                .start = lead,
                .end = lead + word.len,
                .message = try a.print("{s} statement is not within a DO construct", .{if (is_exit) "EXIT" else "CYCLE"}),
                .is_exit = is_exit,
            });
        };
        // a labeled statement closes the DO constructs that name its label
        if (label) |l| while (open.items.len > 0 and open.items[open.items.len - 1] == l) {
            _ = open.pop();
        };
    }
    if (open.items.len > 0) return &.{};
    return out.items;
}
