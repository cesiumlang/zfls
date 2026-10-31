//! Upstream issues about highlighting: semantic tokens, which color names
//! by what they stand for.

const std = @import("std");
const h = @import("harness.zig");

/// The type of the token for the `nth` (0-based) occurrence of `text` on
/// 0-based line `line`; null when that name is not a token
fn tokenType(tokens: []const h.Token, line: i64, text: []const u8, nth: usize) ?[]const u8 {
    var n: usize = 0;
    for (tokens) |t| if (t.line == line and std.mem.eql(u8, t.text, text)) {
        if (n == nth) return t.type;
        n += 1;
    };
    return null;
}

fn expectToken(tokens: []const h.Token, line: i64, text: []const u8, nth: usize, want: ?[]const u8) !void {
    const got = tokenType(tokens, line, text, nth);
    if (want) |wt| {
        try h.expect(got != null and std.mem.eql(u8, got.?, wt), "line {d}: '{s}' is {s}, not {s}", .{ line + 1, text, got orelse "no token", wt });
    } else {
        try h.expect(got == null, "line {d}: '{s}' is a {s} token", .{ line + 1, text, got orelse "" });
    }
}

const shapes =
    \\module shapes
    \\  implicit none
    \\  integer, parameter :: dp = kind(1.0d0)
    \\  type :: circle
    \\    real(dp) :: radius = 1.0_dp
    \\  contains
    \\    procedure :: area
    \\  end type circle
    \\contains
    \\  real(dp) function area(self)
    \\    class(circle), intent(in) :: self
    \\    area = 3.14_dp*self%radius**2
    \\  end function area
    \\  subroutine report(c)
    \\    type(circle), intent(in) :: c
    \\    real(dp) :: total
    \\    total = area(c) + c%area()
    \\  end subroutine report
    \\end module shapes
    \\
;

fn expectUserNames(w: *h.Workspace) !void {
    const toks = try w.semanticTokens("shapes.f90");
    const total = w.pos("shapes.f90", "    total = area", 0, 0).line;
    try expectToken(toks, total, "area", 0, "function");
    try expectToken(toks, total, "c", 0, "parameter");
    try expectToken(toks, total, "total", 0, "variable");
    const decl = w.pos("shapes.f90", "  real(dp) function area", 0, 0).line;
    try expectToken(toks, decl, "area", 0, "function");
    try expectToken(toks, decl, "dp", 0, "variable");
    // `real` is the intrinsic type, colored by the grammar
    try expectToken(toks, decl, "real", 0, null);
    // the result of `area` inside it
    try expectToken(toks, decl + 2, "area", 0, "variable");
    try expectToken(toks, decl + 2, "radius", 0, "property");
    try expectToken(toks, decl + 2, "dp", 0, "variable");
    try expectToken(toks, w.pos("shapes.f90", "  type :: circle", 0, 0).line, "circle", 0, "type");
    try expectToken(toks, 0, "shapes", 0, "namespace");
}

test "#496 user-defined functions are highlighted where they are called" {
    const w = try h.Workspace.init(&.{.{ .name = "shapes.f90", .text = shapes }}, .{});
    defer w.deinit();
    try h.check(496, .fixed, expectUserNames(w));
}

test "Modern Fortran #245 type-bound procedures are highlighted" {
    const w = try h.Workspace.init(&.{.{ .name = "shapes.f90", .text = shapes }}, .{});
    defer w.deinit();
    const toks = try w.semanticTokens("shapes.f90");
    const total = w.pos("shapes.f90", "    total = area", 0, 0).line;
    try h.checkIn(.modern_fortran, 245, .fixed, expectToken(toks, total, "area", 1, "method"));
}

const keywords =
    \\program main
    \\    integer :: module
    \\    integer :: if
    \\
    \\    if = format()
    \\    if (if == 1) then
    \\        if (format() == 1) then
    \\            module = 3
    \\        end if
    \\    end if
    \\
    \\contains
    \\
    \\    integer function format()
    \\        format = 1
    \\    end function
    \\end program
    \\
;

fn expectKeywordNames(w: *h.Workspace) !void {
    const toks = try w.semanticTokens("main.f90");
    // `if = format()`: the variable `if`, the function `format`
    try expectToken(toks, 4, "if", 0, "variable");
    try expectToken(toks, 4, "format", 0, "function");
    // `if (if == 1) then`: the keyword, then the variable
    var ifs: usize = 0;
    for (toks) |t| if (t.line == 5 and std.mem.eql(u8, t.text, "if")) {
        ifs += 1;
    };
    try h.expect(ifs == 1, "{d} tokens for `if` on line 6, not 1 (the variable)", .{ifs});
    try expectToken(toks, 7, "module", 0, "variable");
    try expectToken(toks, 13, "format", 0, "function");
    try expectToken(toks, 14, "format", 0, "variable");
}

test "Modern Fortran #401 variables and functions named like keywords are highlighted as such" {
    const w = try h.Workspace.init(&.{.{ .name = "main.f90", .text = keywords }}, .{});
    defer w.deinit();
    try h.checkIn(.modern_fortran, 401, .fixed, expectKeywordNames(w));
}

test "lines a preprocessor conditional leaves out are comment tokens" {
    const w = try h.Workspace.init(&.{.{ .name = "pp.F90", .text =
        \\program pp
        \\  integer :: n
        \\#ifdef UNDEFINED
        \\  n = 1
        \\#else
        \\  n = 2
        \\#endif
        \\end program pp
        \\
    }}, .{});
    defer w.deinit();
    const toks = try w.semanticTokens("pp.F90");
    try std.testing.expectEqualStrings("comment", tokenType(toks, 3, "  n = 1", 0) orelse "none");
    try std.testing.expectEqualStrings("variable", tokenType(toks, 5, "n", 0) orelse "none");
    // the directives themselves stay active
    try std.testing.expect(tokenType(toks, 2, "#ifdef UNDEFINED", 0) == null);
}
