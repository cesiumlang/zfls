//! Unused names: the local variables of procedures and programs, and the
//! names of USE ONLY lists, that their scope never uses. Found by counting
//! the words of the scope's lines (contained procedures and inactive
//! preprocessor branches included): a name used once besides its
//! declaration is used. Dummy arguments, function results and the names of
//! modules (which other units may use) are not reported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const helpers = @import("helpers.zig");
const objects = @import("objects.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;
const FortranFile = @import("parser.zig").FortranFile;
const selection = @import("selection.zig");

/// 0-based first and last lines of a statement
pub const Lines = struct { first: usize, last: usize };

pub const Unused = struct {
    /// 0-based line and byte columns of the name in its declaration
    line: usize,
    start: usize,
    end: usize,
    name: []const u8,
    kind: enum { variable, use_name },
    /// the lines of a statement that declares nothing else, which the
    /// quick fix removes
    removable: ?Lines = null,
};

pub fn find(a: Allocator, file: *const FortranFile, ast: *Ast) ![]const Unused {
    var out: std.ArrayList(Unused) = .empty;
    if (file.nLines() == 0) return out.items;
    for (ast.scope_list.items) |scope| {
        switch (scope.kind) {
            .subroutine, .function, .program => {},
            else => continue,
        }
        if (scope.file_ast != ast or scope.sline == 0) continue;
        // an interface body declares, it uses nothing
        if (scope.parent) |p| if (p.kind == .interface) continue;
        const first = scope.sline - 1;
        const last = @min(@max(scope.eline, scope.sline) - 1, file.nLines() - 1);
        const counts = (try wordCounts(a, file, first, last)) orelse continue;
        for (scope.childList()) |c| {
            if (c.kind != .variable or c.file_ast != ast or c.sline == 0) continue;
            if (isArgOrResult(scope, c)) continue;
            const lower = try std.ascii.allocLowerString(a, c.name);
            if ((counts.get(lower) orelse 0) > 1) continue;
            const at = findName(file, c.sline - 1, c.name) orelse continue;
            try out.append(a, .{
                .line = at.line,
                .start = at.start,
                .end = at.end,
                .name = c.name,
                .kind = .variable,
                .removable = singleDeclaration(file, c.sline - 1),
            });
        }
        if (scope.data != .scope) continue;
        for (scope.scopeDataConst().use.items) |u| {
            if (u.is_import or u.line_number == 0 or u.only_list.len() == 0) continue;
            for (u.only_list.items.items) |name| {
                if (!isName(name)) continue;
                if ((counts.get(name) orelse 0) > 1) continue;
                const at = findName(file, u.line_number - 1, name) orelse continue;
                try out.append(a, .{
                    .line = at.line,
                    .start = at.start,
                    .end = at.end,
                    .name = at.text,
                    .kind = .use_name,
                    .removable = if (u.only_list.len() == 1 and u.rename_map.count() <= 1) blk: {
                        const st = selection.statementLines(file, u.line_number - 1);
                        break :blk .{ .first = st.first, .last = st.last };
                    } else null,
                });
            }
        }
    }
    return out.items;
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

fn isArgOrResult(scope: *const Obj, c: *const Obj) bool {
    if (scope.procDataOptConst()) |proc| {
        for (proc.arg_objs.items) |arg| if (arg == c) return true;
        if (proc.result_obj == c) return true;
        if (proc.result_name) |r| if (c.nameLowerEql(r)) return true;
    }
    return scope.kind == .function and c.nameLowerEql(scope.name);
}

/// How many times each word (lowercase) occurs in the code of 0-based lines
/// `first`..`last`; null when they include a file, whose code may use names
fn wordCounts(a: Allocator, file: *const FortranFile, first: usize, last: usize) !?std.StringHashMapUnmanaged(usize) {
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    var ln = first;
    while (ln <= last) : (ln += 1) {
        const raw = file.getLine(ln, false) orelse continue;
        if (helpers.isComment(file.fixed, raw)) continue;
        const t = std.mem.trimStart(u8, raw, " \t");
        if (std.ascii.startsWithIgnoreCase(t, "include") or std.mem.startsWith(u8, t, "#") and std.mem.indexOf(u8, t, "include") != null) return null;
        var code = try helpers.stripStrings(a, raw, true);
        if (std.mem.indexOfScalar(u8, code, '!')) |i| code = code[0..i];
        var it = helpers.words(code);
        while (it.next()) |w| {
            const gop = try counts.getOrPut(a, try std.ascii.allocLowerString(a, w.str));
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    return counts;
}

/// Where `name` is written on the statement that starts on 0-based line
/// `line`
fn findName(file: *const FortranFile, line: usize, name: []const u8) ?struct { line: usize, start: usize, end: usize, text: []const u8 } {
    const st = selection.statementLines(file, line);
    var ln = st.first;
    while (ln <= st.last) : (ln += 1) {
        const text = file.getLine(ln, false) orelse continue;
        var it = helpers.words(text);
        while (it.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w.str, name)) return .{ .line = ln, .start = w.start, .end = w.end, .text = w.str };
        }
    }
    return null;
}

/// The lines of the declaration statement on 0-based line `line` when it
/// declares one name only (`real :: x` or `real :: x(10) = 0`)
fn singleDeclaration(file: *const FortranFile, line: usize) ?Lines {
    const st = selection.statementLines(file, line);
    if (st.first != st.last) return null;
    const text = file.getLine(st.first, false) orelse return null;
    const sep = std.mem.indexOf(u8, text, "::") orelse return null;
    var depth: usize = 0;
    for (text[sep + 2 ..]) |ch| switch (ch) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        ',' => if (depth == 0) return null,
        '!' => break,
        else => {},
    };
    return .{ .first = st.first, .last = st.last };
}
