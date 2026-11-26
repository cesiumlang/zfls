//! The argument counts and keywords of an intrinsic function, read from the
//! synopsis of its M_intrinsics page (`result = atan(x) | atan(y, x)`):
//! `[ ]` mark optional arguments, `...` any number of them. Anything the
//! reader does not understand makes the page unread: no entry is better
//! than a wrong one.
//!
//! The pages are not always right. `skip_counts` names those whose count
//! differs from what gfortran 16.1 accepts (recorded 2026-11-24; the same
//! was checked on LLVM Flang 23.1.5), and the module procedures, `skip_keywords` those with a keyword
//! that gfortran or Flang rejects. src/argcheck/_test/intrinsic_arity.zig
//! holds the counts gfortran accepts, to be rechecked when the pages change.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Arity = struct {
    min: usize,
    /// null: any number
    max: ?usize,
    /// sorted; empty when the names are not trusted
    keywords: []const []const u8,
};

/// Pages whose synopsis gives other counts than the compilers accept
pub const skip_counts = [_][]const u8{
    "bessel_yn",        "image_index",      "max",          "min",      "maxloc", "minloc",
    // procedures of modules, and F2023 names that gfortran lacks
    "compiler_options", "compiler_version", "c_associated", "c_funloc", "c_loc",  "c_sizeof",
    "next",             "previous",
};

/// Pages with a keyword of another name than the compilers' (or one that
/// only one of the argument forms has)
pub const skip_keywords = [_][]const u8{
    "aint",     "atan",  "atand",        "cmplx", "lge",      "lle", "llt",
    "new_line", "norm2", "out_of_range", "real",  "transfer",
};

fn isSkipped(list: []const []const u8, name: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// The counts and keywords of intrinsic function `name` that `text`, its
/// page, gives; null for a subroutine or a page not understood
pub fn parse(a: Allocator, name: []const u8, text: []const u8) Allocator.Error!?Arity {
    if (isSkipped(&skip_counts, name)) return null;
    const head = std.mem.find(u8, text, "### **Synopsis**") orelse return null;
    const tail = std.mem.findPos(u8, text, head, "### **Characteristics**") orelse return null;
    var min: ?usize = null;
    var max: usize = 0;
    var any_number = false;
    var names: std.ArrayList([]const u8) = .empty;
    var in_block = false;
    var first_line = true;
    var is_call_block = false;
    var pending: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text[head..tail], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "```")) {
            in_block = !in_block and std.mem.startsWith(u8, line, "```fortran");
            first_line = true;
            pending.clearRetainingCapacity();
            continue;
        }
        if (!in_block or line.len == 0) continue;
        // a continued line: its parts are one
        var piece = line;
        if (pending.items.len > 0 and piece[0] == '&') piece = std.mem.trimStart(u8, piece[1..], " \t");
        const continued = piece.len > 0 and piece[piece.len - 1] == '&';
        if (continued) piece = std.mem.trimEnd(u8, piece[0 .. piece.len - 1], " \t");
        try pending.appendSlice(a, piece);
        if (continued) {
            try pending.append(a, ' ');
            continue;
        }
        const logical = pending.items;
        defer pending.clearRetainingCapacity();
        const body = resultBody(logical);
        if (first_line) is_call_block = body != null;
        first_line = false;
        if (!is_call_block) continue;
        const call = body orelse continue;
        var rest = call;
        while (true) {
            const bar = topLevelBar(rest);
            const part = std.mem.trim(u8, rest[0 .. bar orelse rest.len], " ");
            const alt = (try alternative(a, name, part, &names)) orelse return null;
            min = @min(min orelse alt.required, alt.required);
            max = @max(max, alt.total);
            any_number = any_number or alt.variable;
            if (bar) |b| rest = rest[b + 1 ..] else break;
        }
    }
    const lo = min orelse return null;
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var unique: std.ArrayList([]const u8) = .empty;
    for (names.items) |n| if (unique.items.len == 0 or !std.mem.eql(u8, unique.items[unique.items.len - 1], n)) try unique.append(a, n);
    const trusted = !any_number and !isSkipped(&skip_keywords, name);
    return .{ .min = lo, .max = if (any_number) null else max, .keywords = if (trusted) unique.items else &.{} };
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// What follows `result =` on a line, else null
fn resultBody(line: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(line, "result")) return null;
    const rest = std.mem.trimStart(u8, line["result".len..], " ");
    if (rest.len == 0 or rest[0] != '=') return null;
    return std.mem.trim(u8, rest[1..], " ");
}

/// The first `|` outside parentheses and brackets
fn topLevelBar(s: []const u8) ?usize {
    var depth: usize = 0;
    for (s, 0..) |c, i| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        '|' => if (depth == 0) return i,
        else => {},
    };
    return null;
}

const Alternative = struct { required: usize, total: usize, variable: bool };

/// One form of the call, `name(x [,y] [,kind])`, its keywords added to
/// `names`; null when it is not that
fn alternative(a: Allocator, name: []const u8, part: []const u8, names: *std.ArrayList([]const u8)) Allocator.Error!?Alternative {
    if (!std.ascii.startsWithIgnoreCase(part, name)) return null;
    var rest = std.mem.trimStart(u8, part[name.len..], " ");
    if (rest.len < 2 or rest[0] != '(' or rest[rest.len - 1] != ')') return null;
    rest = rest[1 .. rest.len - 1];
    var alt: Alternative = .{ .required = 0, .total = 0, .variable = false };
    var depth: usize = 0;
    var i: usize = 0;
    while (i < rest.len) {
        const c = rest[i];
        switch (c) {
            ' ', ',' => i += 1,
            '[' => {
                depth += 1;
                i += 1;
            },
            ']' => {
                if (depth == 0) return null;
                depth -= 1;
                i += 1;
            },
            '.' => {
                if (!std.mem.startsWith(u8, rest[i..], "...")) return null;
                alt.variable = true;
                i += 3;
            },
            else => {
                if (!(std.ascii.isAlphabetic(c) or c == '_')) return null;
                var end = i;
                while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
                try names.append(a, try std.ascii.allocLowerString(a, rest[i..end]));
                alt.total += 1;
                if (depth == 0) alt.required += 1;
                i = end;
            },
        }
    }
    if (depth != 0) return null;
    return alt;
}

fn expectArity(text: []const u8, name: []const u8, min: usize, max: ?usize, keywords: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = (try parse(arena.allocator(), name, text)) orelse return error.NotRead;
    try std.testing.expectEqual(min, got.min);
    try std.testing.expectEqual(max, got.max);
    try std.testing.expectEqual(keywords.len, got.keywords.len);
    for (keywords, got.keywords) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "synopses with optional arguments, alternatives and any number" {
    const atan = "## atan\n\n### **Synopsis**\n```fortran\n    result = atan(x) | atan(y, x)\n```\n```fortran\n  elemental function atan(y,x)\n```\n### **Characteristics**\n";
    try expectArity(atan, "atan", 1, 2, &.{});
    const index = "### **Synopsis**\n```fortran\nresult = index( string, substring [,back] [,kind] )\n```\n### **Characteristics**\n";
    try expectArity(index, "index", 2, 4, &.{ "back", "kind", "string", "substring" });
    const varargs = "### **Synopsis**\n```fortran\n    result = mad(a1, a2, a3, ...)\n```\n### **Characteristics**\n";
    try expectArity(varargs, "mad", 3, null, &.{});
    const nested = "### **Synopsis**\n```fortran\n   result = tof(array [,dim [,mask]])\n```\n### **Characteristics**\n";
    try expectArity(nested, "tof", 1, 3, &.{ "array", "dim", "mask" });
    const split = "### **Synopsis**\n```fortran\n   result = reduce (array, operation, dim  &\n   & [,mask] [,identity] [,ordered] )\n```\n### **Characteristics**\n";
    try expectArity(split, "reduce", 3, 6, &.{ "array", "dim", "identity", "mask", "operation", "ordered" });
}

test "pages that are not understood" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a subroutine
    try std.testing.expect(try parse(a, "cpu_time", "### **Synopsis**\n```fortran\n    call cpu_time(time)\n```\n### **Characteristics**\n") == null);
    // the bar inside the parentheses
    try std.testing.expect(try parse(a, "sum", "### **Synopsis**\n```fortran\n   result = sum(array [,dim[,mask]] | [mask] )\n```\n### **Characteristics**\n") == null);
    // no synopsis, a skipped page
    try std.testing.expect(try parse(a, "x", "nothing") == null);
    try std.testing.expect(try parse(a, "max", "### **Synopsis**\n```fortran\nresult = max(a1, a2)\n```\n### **Characteristics**\n") == null);
}
