//! Part of the parser (parse.zig): ENTRY statements (#554). An entry of a
//! subroutine or function is a procedure of the same kind in the scope
//! that has the procedure (a module, the host, or the file), as compilers
//! declare it: `entry e2(x, y) [result(r)]`. Its dummy arguments and
//! result are variables of the procedure it is an entry of
//! (`Procedure.entry_of`), which linking finds there. Its object is no
//! scope of the lines of the procedure: names on them are the
//! procedure's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objects = @import("../objects.zig");
const implicit = @import("../implicit.zig");
const Obj = objects.Obj;
const Ast = objects.Ast;

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// An ENTRY statement's parts
pub const Entry = struct { name: []const u8, args: []const u8, result: ?[]const u8 };

/// `entry name [(args)] [result(r)] [bind(...)]`, or null
pub fn parse(code: []const u8) ?Entry {
    var s = std.mem.trim(u8, code, " \t");
    if (!std.ascii.startsWithIgnoreCase(s, "entry") or s.len <= 5 or s[5] != ' ') return null;
    s = std.mem.trimStart(u8, s[5..], " ");
    var i: usize = 0;
    while (i < s.len and isNameChar(s[i])) i += 1;
    if (i == 0 or !std.ascii.isAlphabetic(s[0])) return null;
    const name = s[0..i];
    var rest = std.mem.trimStart(u8, s[i..], " ");
    var args: []const u8 = "";
    if (rest.len > 0 and rest[0] == '(') {
        const close = std.mem.findScalar(u8, rest, ')') orelse return null;
        args = std.mem.trim(u8, rest[1..close], " ");
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " ");
    }
    var result: ?[]const u8 = null;
    if (std.ascii.startsWithIgnoreCase(rest, "result")) {
        const after = std.mem.trimStart(u8, rest["result".len..], " ");
        if (after.len > 0 and after[0] == '(') if (std.mem.findScalar(u8, after, ')')) |close| {
            const r = std.mem.trim(u8, after[1..close], " ");
            if (r.len > 0) result = r;
        };
    }
    return .{ .name = name, .args = args, .result = result };
}

/// Reads statement `code` (no label, no comment), at line `line_no`, as an
/// ENTRY statement of the current scope if it is one: true when it is
pub fn read(ast: *Ast, a: Allocator, code: []const u8, line_no: usize) !bool {
    const e = parse(code) orelse return false;
    const owner = ast.current_scope orelse return false;
    if (owner.kind != .subroutine and owner.kind != .function) return false;
    const pa = ast.allocator();
    const o = if (owner.kind == .subroutine)
        try Obj.newSubroutine(ast, line_no, e.name, e.args, false, owner.keywords.items)
    else
        try Obj.newFunction(ast, line_no, e.name, .{
            .args = e.args,
            .keywords = owner.keywords.items,
            .result_name = e.result,
            .result_type = implicit.typeOf(owner, e.result orelse e.name),
        });
    o.procData().entry_of = owner;
    const lname = try std.ascii.allocLowerString(a, e.name);
    if (owner.parent) |p| {
        o.fqsn = try std.mem.concat(pa, u8, &.{ p.fqsn, "::", lname });
        try p.addChild(o);
    } else {
        o.fqsn = try pa.dupe(u8, lname);
        try ast.global_dict.put(pa, o.fqsn, o);
    }
    try ast.linkable_objs.append(pa, o);
    try ast.entry_list.append(pa, o);
    // the procedure's summary keeps the variables the entry names
    const op = owner.procData();
    var names: std.ArrayList([]const u8) = .empty;
    if (op.entry_names.len > 0) try names.append(a, op.entry_names);
    var it = std.mem.splitScalar(u8, e.args, ',');
    while (it.next()) |arg| {
        const t = std.mem.trim(u8, arg, " ");
        if (t.len > 0) try names.append(a, t);
    }
    if (owner.kind == .function) try names.append(a, e.result orelse e.name);
    op.entry_names = try std.ascii.allocLowerString(pa, try std.mem.join(a, ",", names.items));
    ast.last_obj = o;
    if (ast.pending_doc) |d| {
        o.addDoc(d);
        ast.pending_doc = null;
    }
    return true;
}

test parse {
    const e = parse("  entry other_entry(x, y)").?;
    try std.testing.expectEqualStrings("other_entry", e.name);
    try std.testing.expectEqualStrings("x, y", e.args);
    try std.testing.expect(e.result == null);
    const r = parse("ENTRY H (A) RESULT (R)").?;
    try std.testing.expectEqualStrings("H", r.name);
    try std.testing.expectEqualStrings("R", r.result.?);
    try std.testing.expectEqualStrings("", parse("entry e3").?.args);
    try std.testing.expect(parse("entry = 1") == null);
    try std.testing.expect(parse("entryx(1) = 2") == null);
}
