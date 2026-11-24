//! Operands of the wrong types in the right side of an assignment, and the
//! assignments of what is not a literal (#876), verified on gfortran 16.1,
//! Flang 23.1.5 and ifx 2026.2.0: all three reject a CHARACTER variable
//! mixed with a numeric or logical operand, `//` with anything but
//! CHARACTER, and an assignment between CHARACTER and the other types; a
//! character literal in arithmetic or a comparison (`r + 'a'`) is ifx's to
//! accept.

const std = @import("std");
const h = @import("harness.zig");

fn collect(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, "assignment-type")) {
        try out.append(w.a(), try w.a().print("{d}: {s}", .{ d.line + 1, d.message }));
    };
    return out.items;
}

fn expectAll(got: []const []const u8, want: []const []const u8) !void {
    if (want.len != got.len) {
        for (got) |g| std.debug.print("got: {s}\n", .{g});
        return error.TestExpectedEqual;
    }
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
}

fn workspace(comptime dialect: []const u8, text: []const u8) !*h.Workspace {
    const opts = "{\"lint_dialect\": \"" ++ dialect ++ "\"}";
    return h.Workspace.init(&.{.{ .name = "a.f90", .text = text }}, .{ .init_options = opts });
}

const clashes =
    \\program p
    \\  implicit none
    \\  character(len=3) :: c
    \\  real :: r
    \\  integer :: i
    \\  logical :: l
    \\  complex :: z
    \\  i = r + c
    \\  c = 'a' // 1
    \\  c = 'a' // i
    \\  l = c == 1
    \\  l = r > c
    \\  c = l
    \\  c = z
    \\  r = c
    \\  l = c
    \\  i = r + 'a'
    \\  l = r > 'a'
    \\  c = .true.
    \\  i = 2 * i + c
    \\  l = i + 1 < c // 'a'
    \\end program
    \\
;

const all_dialects = [_][]const u8{
    "8: A CHARACTER operand and a REAL operand in an arithmetic operation",
    "9: The operands of // must be CHARACTER, not INTEGER",
    "10: The operands of // must be CHARACTER, not INTEGER",
    "11: A CHARACTER operand and a INTEGER operand in a comparison",
    "12: A CHARACTER operand and a REAL operand in a comparison",
};

test "CHARACTER mixed with other types in an expression: every dialect" {
    inline for ([_][]const u8{ "neutral", "ifx" }) |d| {
        const w = try workspace(d, clashes);
        defer w.deinit();
        try expectAll(try collect(w, "a.f90"), &(all_dialects ++ [_][]const u8{
            "13: Cannot assign a value of type LOGICAL to CHARACTER variable c",
            "14: Cannot assign a value of type COMPLEX to CHARACTER variable c",
            "15: Cannot assign a value of type CHARACTER to REAL variable r",
            "16: Cannot assign a value of type CHARACTER to LOGICAL variable l",
            "19: Cannot assign a value of type LOGICAL to CHARACTER variable c",
            "20: A CHARACTER operand and a INTEGER operand in an arithmetic operation",
            "21: A CHARACTER operand and a INTEGER operand in a comparison",
        }));
    }
}

test "a character literal in arithmetic or a comparison: gfortran's and Flang's" {
    inline for ([_][]const u8{ "gfortran", "flang" }) |d| {
        const w = try workspace(d, clashes);
        defer w.deinit();
        try expectAll(try collect(w, "a.f90"), &(all_dialects ++ [_][]const u8{
            "13: Cannot assign a value of type LOGICAL to CHARACTER variable c",
            "14: Cannot assign a value of type COMPLEX to CHARACTER variable c",
            "15: Cannot assign a value of type CHARACTER to REAL variable r",
            "16: Cannot assign a value of type CHARACTER to LOGICAL variable l",
            "17: A CHARACTER operand and a REAL operand in an arithmetic operation",
            "18: A CHARACTER operand and a REAL operand in a comparison",
            "19: Cannot assign a value of type LOGICAL to CHARACTER variable c",
            "20: A CHARACTER operand and a INTEGER operand in an arithmetic operation",
            "21: A CHARACTER operand and a INTEGER operand in a comparison",
        }));
    }
}

test "valid expressions, and operators the workspace defines, are not reported" {
    const w = try workspace("gfortran",
        \\module ops
        \\  implicit none
        \\  interface operator(+)
        \\    module procedure plus
        \\  end interface
        \\contains
        \\  function plus(a, b)
        \\    real, intent(in) :: a
        \\    character(len=*), intent(in) :: b
        \\    real :: plus
        \\    plus = a + len(b)
        \\  end function
        \\end module
        \\program p
        \\  use ops
        \\  implicit none
        \\  character(len=3) :: c
        \\  real :: r, a(3)
        \\  integer :: i
        \\  logical :: l
        \\  c = 'a' // c
        \\  i = i + 2 * i
        \\  l = c == 'a' .and. r > 1.0
        \\  c = c(1:2) // 'x'
        \\  l = c < 'b'
        \\  r = real(i) + 1.0 + a(2) * 2.0
        \\  r = r + c
        \\  i = len(c) + 1
        \\  c = trim(c) // 'x'
        \\end program
        \\
    );
    defer w.deinit();
    try expectAll(try collect(w, "a.f90"), &.{});
}
