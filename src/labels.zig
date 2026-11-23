//! Statement labels (#850): a label defined twice in a scoping unit, and a
//! label that a GO TO, a DO, a FORMAT reference or an I/O specifier names
//! and the unit does not define. gfortran, Flang and ifx all report both.
//! The labels are those of the first line of each statement, read by
//! constructs.zig; a file with an INCLUDE (which may define them) or a
//! preprocessor conditional that leaves lines out is not checked for
//! missing labels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const constructs = @import("constructs.zig");
const objects = @import("objects.zig");
const selection = @import("selection.zig");
const inactive_lines = @import("inactive.zig");
const FortranFile = @import("parser.zig").FortranFile;

const Obj = objects.Obj;
const Ast = objects.Ast;

pub const Kind = enum { twice, missing };

pub const Problem = struct { line: usize, start: usize, end: usize, message: []const u8, kind: Kind };

/// The scoping unit of a label: the program unit around, the BLOCK
/// constructs and the others inside it counting as one
fn unitOf(scope: ?*Obj) ?*Obj {
    var cur = scope;
    while (cur) |s| : (cur = s.parent) switch (s.kind) {
        .do_, .if_, .where, .enum_, .associate, .select, .block, .type => {},
        else => return s,
    };
    return null;
}

pub fn labelValue(file: *const FortranFile, s: constructs.Span) ?u32 {
    const text = file.getLine(s.line, false) orelse return null;
    if (s.end > text.len) return null;
    return std.fmt.parseInt(u32, text[s.start..s.end], 10) catch null;
}

const Ref = struct { span: constructs.Span, label: u32 };

const Unit = struct {
    defs: std.AutoHashMapUnmanaged(u32, constructs.Span) = .empty,
    refs: std.ArrayList(Ref) = .empty,
};

pub fn check(a: Allocator, file: *const FortranFile, ast: *Ast) ![]const Problem {
    var out: std.ArrayList(Problem) = .empty;
    const n = file.nLines();
    if (n == 0) return out.items;
    const inner = try ast.innerScopes(a, n);
    const skipped = try inactive_lines.of(a, file);
    const inactive = skipped.lines;
    const all_active = !skipped.any;
    const trusted = ast.include_statements.items.len == 0 and all_active;
    var units: std.AutoHashMapUnmanaged(?*Obj, *Unit) = .empty;
    var ln: usize = 0;
    while (ln < n) {
        const st = selection.statementLines(file, ln);
        defer ln = st.last + 1;
        if (inactive[ln]) continue;
        const found = try constructs.labelsOf(a, file, ln);
        if (found.def == null and found.refs.len == 0) continue;
        const key = unitOf(inner.at(ln + 1));
        const gop = try units.getOrPut(a, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try a.create(Unit);
            gop.value_ptr.*.* = .{};
        }
        const u = gop.value_ptr.*;
        if (found.def) |d| if (labelValue(file, d)) |v| {
            const prev = try u.defs.getOrPut(a, v);
            if (prev.found_existing) {
                try out.append(a, .{ .line = d.line, .start = d.start, .end = d.end, .message = try a.print("Label {d} is defined twice in this scope (first on line {d})", .{ v, prev.value_ptr.line + 1 }), .kind = .twice });
            } else prev.value_ptr.* = d;
        };
        for (found.refs) |r| if (labelValue(file, r)) |v| try u.refs.append(a, .{ .span = r, .label = v });
    }
    if (!trusted) return out.items;
    var it = units.valueIterator();
    while (it.next()) |u| for (u.*.refs.items) |r| {
        if (u.*.defs.contains(r.label)) continue;
        try out.append(a, .{ .line = r.span.line, .start = r.span.start, .end = r.span.end, .message = try a.print("Label {d} is not defined in this scope", .{r.label}), .kind = .missing });
    };
    return out.items;
}
