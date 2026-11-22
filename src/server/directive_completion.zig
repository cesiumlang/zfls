//! Completion of the names of OpenMP (`!$omp`) and OpenACC (`!$acc`)
//! directives and clauses (#742), from the table hover documents them with
//! (data/directives.zig): a directive's name after the sentinel, then the
//! directives' words and the clauses. In a clause's parentheses the names
//! of the scope complete as elsewhere.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp.zig");
const directives = @import("../data/directives.zig");
const FortranFile = @import("../parser.zig").FortranFile;

/// A directive line: whether OpenMP's, where its words start, whether it
/// continues the directive of the line before, the case of its sentinel
const Sentinel = struct { omp: bool, start: usize, continued: bool, upper: bool };

/// The sentinel of a directive line, `!$omp` (fixed form also `c$omp` and
/// `*$omp` in column 1), or null
fn sentinelOf(fixed: bool, text: []const u8) ?Sentinel {
    var i: usize = 0;
    if (!fixed) while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {};
    if (text.len < i + 5 or text[i + 1] != '$') return null;
    switch (text[i]) {
        '!' => {},
        'c', 'C', '*' => if (!fixed or i != 0) return null,
        else => return null,
    }
    const word = text[i + 2 .. i + 5];
    const omp = std.ascii.eqlIgnoreCase(word, "omp");
    if (!omp and !std.ascii.eqlIgnoreCase(word, "acc")) return null;
    var start = i + 5;
    // a continuation: `!$omp&` (free form), a mark in column 6 (fixed form)
    var continued = false;
    if (fixed) {
        if (text.len > 5 and start == 5 and text[5] != ' ' and text[5] != '0') {
            continued = true;
            start = 6;
        }
    } else {
        var j = start;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        if (j < text.len and text[j] == '&') {
            continued = true;
            start = j + 1;
        }
    }
    if (start < text.len and !(text[start] == ' ' or text[start] == '\t' or continued)) return null;
    return .{ .omp = omp, .start = start, .continued = continued, .upper = std.ascii.isUpper(word[0]) };
}

/// Whether line `line` (0-based) continues the directive of the line
/// before it, which ends with `&` (free form)
fn continuesDirective(file: *const FortranFile, line: usize) bool {
    if (file.fixed or line == 0) return false;
    const prev = file.getLine(line - 1, false) orelse return false;
    if (sentinelOf(false, prev) == null) return false;
    return std.mem.endsWith(u8, std.mem.trimEnd(u8, prev, " \t\r"), "&");
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The completion items at byte `col` of line `line` (0-based) of a
/// directive, or null on another line or in a clause's parentheses
pub fn items(a: Allocator, file: *const FortranFile, line: usize, col: usize) !?[]const lsp.CompletionItem {
    const text = file.getLine(line, false) orelse return null;
    const s = sentinelOf(file.fixed, text) orelse return null;
    const c = @min(col, text.len);
    if (c < s.start) return null;
    var depth: usize = 0;
    for (text[s.start..c]) |ch| switch (ch) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        else => {},
    };
    if (depth > 0) return null;
    var w = c;
    while (w > s.start and isWordChar(text[w - 1])) w -= 1;
    const typed = text[w..c];
    // the directive's first word, or one after it
    const first = !s.continued and !continuesDirective(file, line) and std.mem.trim(u8, text[s.start..w], " \t").len == 0;
    const table: []const directives.Directive = if (s.omp) &directives.omp else &directives.acc;
    const what = if (s.omp) "OpenMP" else "OpenACC";
    var out: std.ArrayList(lsp.CompletionItem) = .empty;
    for (table) |d| {
        if (first and d.clause) continue;
        if (!std.ascii.startsWithIgnoreCase(d.name, typed)) continue;
        const label = if (s.upper) try std.ascii.allocUpperString(a, d.name) else d.name;
        try out.append(a, .{
            .label = label,
            .kind = 14,
            .detail = try std.mem.concat(a, u8, &.{ what, if (d.clause) " clause" else " directive" }),
            .documentation = .{ .value = d.doc },
        });
    }
    return out.items;
}
