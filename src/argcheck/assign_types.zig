//! Assignments and conditions of the wrong type (#850), by the categories
//! of intrinsic types (argcheck/typing.zig): a numeric literal for a
//! character variable (all dialects: gfortran, Flang and ifx report it), a
//! character value for a numeric or logical variable and an `if (i)` on a
//! non-logical variable (gfortran and Flang report them, ifx accepts both).
//! Not checked where an `assignment(=)` interface exists in the workspace.

const std = @import("std");
const helpers = @import("../helpers.zig");
const typing = @import("typing.zig");
const argcheck = @import("../argcheck.zig");
const dimensions = @import("../objects/dimensions.zig");
const objects = @import("../objects.zig");
const Dialect = @import("../dialect.zig").Dialect;

const Checker = argcheck.Checker;
const Joined = argcheck.Joined;
const Obj = objects.Obj;
const Category = typing.Category;

fn typeName(cat: Category) []const u8 {
    return if (cat == .character) "CHARACTER" else typing.typeName(cat);
}

fn numericOrLogical(cat: Category) bool {
    return typing.numeric(cat) or cat == .logical;
}

/// Whether `text` holds an `assignment(=)` interface
pub fn hasDefinedAssignment(text: []const u8) bool {
    var rest = text;
    while (std.ascii.findIgnoreCase(rest, "assignment")) |i| {
        const after = std.mem.trimStart(u8, rest[i + "assignment".len ..], " ");
        if (std.mem.startsWith(u8, after, "(")) return true;
        rest = rest[i + "assignment".len ..];
    }
    return false;
}

/// Whether the workspace, or the file checked, has an `assignment(=)`
/// interface; told once, as it takes every line of every file
fn definedAssignment(c: *Checker) bool {
    if (c.defined_assignment) |known| return known;
    var found = false;
    for (c.files) |f| {
        for (0..f.nLines()) |ln| {
            if (hasDefinedAssignment(f.getLine(ln, false) orelse continue)) {
                found = true;
                break;
            }
        }
        if (found) break;
    }
    c.defined_assignment = found;
    return found;
}

/// The variable a plain assignment `x = ...` or `x(i) = ...` assigns to,
/// and the text after its `=`
fn target(c: *Checker, text: []const u8, first: helpers.Word, scope: ?*Obj, line_no: usize) !?struct { v: *Obj, rhs_at: usize } {
    var k = first.end;
    while (k < text.len and text[k] == ' ') k += 1;
    if (k < text.len and text[k] == '(') k = (typing.matching(text, k) orelse return null) + 1;
    while (k < text.len and text[k] == ' ') k += 1;
    if (k >= text.len or text[k] != '=') return null;
    if (k + 1 < text.len and (text[k + 1] == '=' or text[k + 1] == '>')) return null;
    const v = (try c.lookup(scope, first.str, line_no)) orelse return null;
    if (v.kind != .variable or dimensions.isAssociateName(v) or v.linkObj() != null) return null;
    return .{ .v = v, .rhs_at = k + 1 };
}

pub fn check(c: *Checker, j: Joined, s: usize, text: []const u8, first: helpers.Word, scope: ?*Obj, line_no: usize) !void {
    const strict = c.dialect.applies(.initMany(&.{ .gfortran, .flang }));
    if (std.ascii.eqlIgnoreCase(first.str, "if")) return checkCondition(c, j, s, text, first, scope, line_no, strict);
    const t = (try target(c, text, first, scope, line_no)) orelse return;
    const lhs = typing.varCategory(t.v);
    const rhs_text = std.mem.trim(u8, text[t.rhs_at..], " ");
    const rhs = (try c.exprType(rhs_text, scope, line_no, 0)) orelse return;
    // a literal: expressions are not told (`4_'h' // char(235, kind=4)`)
    if (!rhs.literal) return;
    const bad = (lhs == .character and typing.numeric(rhs.cat)) or
        (strict and numericOrLogical(lhs) and rhs.cat == .character);
    if (!bad or definedAssignment(c)) return;
    const at = t.rhs_at + (std.mem.findNone(u8, text[t.rhs_at..], " ") orelse 0);
    try c.report(j, s + first.start, s + at, .assignment_type, "Cannot assign a value of type {s} to {s} variable {s}", .{ typeName(rhs.cat), typeName(lhs), t.v.name });
}

/// `if (i) ...` for a variable of a type that is not logical
fn checkCondition(c: *Checker, j: Joined, s: usize, text: []const u8, first: helpers.Word, scope: ?*Obj, line_no: usize, strict: bool) !void {
    if (!strict) return;
    var k = first.end;
    while (k < text.len and text[k] == ' ') k += 1;
    if (k >= text.len or text[k] != '(') return;
    const close = typing.matching(text, k) orelse return;
    // the arithmetic IF
    const after = std.mem.trimStart(u8, text[close + 1 ..], " ");
    if (after.len == 0 or std.ascii.isDigit(after[0])) return;
    const cond = std.mem.trim(u8, text[k + 1 .. close], " ");
    if (!typing.isName(cond)) return;
    const v = (try c.lookup(scope, cond, line_no)) orelse return;
    if (v.kind != .variable or dimensions.isAssociateName(v) or v.linkObj() != null) return;
    const cat = typing.varCategory(v);
    if (!(typing.numeric(cat) or cat == .character)) return;
    const at = k + 1 + (std.mem.find(u8, text[k + 1 ..], cond) orelse 0);
    try c.report(j, s + at, s + at + cond.len, .condition_type, "The condition of IF must be logical, {s} is {s}", .{ v.name, typeName(cat) });
}
