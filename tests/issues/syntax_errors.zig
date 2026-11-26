//! Statements the compilers reject as malformed (#875), verified on gfortran
//! 16.1, Flang 23.1.5 and ifx 2026.2.0: unmatched parentheses, an
//! expression that ends in an operator, a `type(t)` of an ABSTRACT type, an
//! `extends` of a type nothing defines, a dummy argument of a PURE function
//! without INTENT(IN) (INTENT(OUT) and INTENT(INOUT) are gfortran's and ifx's
//! errors, Flang accepts them), and an unknown specifier of READ or WRITE.

const std = @import("std");
const h = @import("harness.zig");

const codes = [_][]const u8{ "unbalanced-parentheses", "dangling-operator", "abstract-type-declared", "extends-unknown-type", "pure-function-argument", "unknown-io-specifier" };

fn collect(w: *h.Workspace, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| {
        for (codes) |c| if (std.mem.eql(u8, d.code, c)) {
            try out.append(w.a(), try w.a().print("{d}: {s}: {s}", .{ d.line + 1, d.code, d.message }));
        };
    }
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

const malformed =
    \\module m
    \\  implicit none
    \\  type, abstract :: shape
    \\    integer :: n
    \\  end type
    \\  type, extends(shape) :: circle
    \\  end type
    \\  type, extends(nosuch) :: bad
    \\  end type
    \\contains
    \\  pure function f(x, y, z, w)
    \\    integer :: x
    \\    integer, intent(inout) :: y
    \\    integer, intent(in) :: z
    \\    integer, value :: w
    \\    integer :: f
    \\    f = x + y + z + w
    \\  end function
    \\  subroutine s
    \\    type(shape) :: a
    \\    class(shape), allocatable :: b
    \\    type(circle) :: c
    \\    integer :: i, j, u
    \\    real :: r
    \\    i = j +
    \\    i = (j + 1
    \\    r = j + 1)
    \\    i = j **
    \\    write (u, fmt=*, bogus=1) i
    \\    write (u, *, iostat=j) i
    \\    read (u, '(a)', end=10) i
    \\10  continue
    \\    i = j + &
    \\        1
    \\    i = j + &
    \\
    \\        1
    \\  end subroutine
    \\end module
    \\
;

const common = [_][]const u8{
    "8: extends-unknown-type: The type nosuch that this type extends is not defined",
    "11: pure-function-argument: The argument x of the PURE function f needs INTENT(IN) or VALUE",
};

const inout = "11: pure-function-argument: The argument y of the PURE function f is INTENT(INOUT), not INTENT(IN)";

const rest = [_][]const u8{
    "20: abstract-type-declared: The type shape is ABSTRACT: declare a CLASS(shape) variable",
    "25: dangling-operator: The expression ends in the operator +",
    "26: unbalanced-parentheses: This ( has no matching )",
    "27: unbalanced-parentheses: This ) has no matching (",
    "28: dangling-operator: The expression ends in the operator *",
    "29: unknown-io-specifier: bogus is no specifier of a write statement",
};

test "malformed statements: every dialect" {
    inline for ([_][]const u8{ "neutral", "flang" }) |d| {
        const w = try workspace(d, malformed);
        defer w.deinit();
        try expectAll(try collect(w, "a.f90"), &(common ++ rest));
    }
}

test "INTENT(INOUT) of a PURE function's dummy argument: gfortran's and ifx's" {
    inline for ([_][]const u8{ "gfortran", "ifx" }) |d| {
        const w = try workspace(d, malformed);
        defer w.deinit();
        try expectAll(try collect(w, "a.f90"), &(common ++ [_][]const u8{inout} ++ rest));
    }
}

test "valid statements are not reported" {
    const w = try workspace("gfortran",
        \\module m
        \\  implicit none
        \\  type, abstract :: shape
        \\  end type
        \\  type, extends(shape) :: circle
        \\    real :: r
        \\  end type
        \\contains
        \\  pure function f(x, y, p)
        \\    integer, intent(in) :: x
        \\    integer, value :: y
        \\    integer, pointer :: p
        \\    integer :: f
        \\    f = x + y
        \\  end function
        \\  subroutine s(u)
        \\    class(shape), allocatable :: b
        \\    type(circle) :: c
        \\    integer :: u, i, j
        \\    real :: a(3)
        \\    character(len=3) :: t
        \\    i = (j + 1) * (j - 1)
        \\    a = (/ 1.0, 2.0, 3.0 /)
        \\    t = '(('
        \\    i = j + &
        \\        1
        \\    write (unit=u, fmt='(a)', iostat=i, advance='no') t
        \\    read (u, *, end=10, err=10) i
        \\    print *, i, ')'
        \\10  continue
        \\  end subroutine
        \\end module
        \\
    );
    defer w.deinit();
    try expectAll(try collect(w, "a.f90"), &.{});
}

test "LEADING_ZERO= of READ and WRITE is an error in gfortran only (#899)" {
    const text =
        \\program p
        \\  character(len=20) :: s
        \\  write (s, '(F8.3)', leading_zero='suppress') 0.5
        \\end program
        \\
    ;
    inline for ([_][]const u8{ "neutral", "ifx", "flang", "gfortran" }) |d| {
        const w = try workspace(d, text);
        defer w.deinit();
        const got = try collect(w, "a.f90");
        if (comptime std.mem.eql(u8, d, "gfortran")) {
            try expectAll(got, &.{"3: unknown-io-specifier: leading_zero is no specifier of a write statement"});
        } else try expectAll(got, &.{});
    }
}
