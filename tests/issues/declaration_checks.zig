//! Declarations that compilers reject (#850), verified on gfortran 16.1,
//! Flang 23.1.5 and ifx 2026.2.0: a named constant with no value and a
//! dummy argument named twice (all three report both); a kind that the
//! compiler does not have (each compiler has its own).

const std = @import("std");
const h = @import("harness.zig");

fn collect(w: *h.Workspace, name: []const u8, code: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try w.diagnostics(name)) |d| if (std.mem.eql(u8, d.code, code)) {
        try out.append(w.a(), try w.a().print("{d}: {s}", .{ d.line + 1, d.message }));
    };
    return out.items;
}

fn expectAll(got: []const []const u8, want: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("got: {any}\n", .{got});
        return error.TestExpectedEqual;
    }
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
}

fn workspace(comptime dialect: []const u8, text: []const u8) !*h.Workspace {
    const opts = "{\"lint_dialect\": \"" ++ dialect ++ "\"}";
    return h.Workspace.init(&.{.{ .name = "a.f90", .text = text }}, .{ .init_options = opts });
}

test "a named constant with no value" {
    const w = try workspace("neutral",
        \\program p
        \\  implicit none
        \\  integer, parameter :: n
        \\  integer, parameter :: m = 3, k
        \\  real, parameter :: r(2)
        \\  integer, parameter :: ok = 1, fine(2) = [1, 2]
        \\  character(len=3), parameter :: s = 'abc'
        \\  integer :: v
        \\end program
        \\
    );
    defer w.deinit();
    try expectAll(try collect(w, "a.f90", "parameter-without-value"), &.{
        "3: Named constant n has no value",
        "4: Named constant k has no value",
        "5: Named constant r has no value",
    });
}

test "a dummy argument named twice" {
    const w = try workspace("neutral",
        \\subroutine s(a, b, a)
        \\  implicit none
        \\  integer :: a, b
        \\end subroutine
        \\real function f(x, X)
        \\  implicit none
        \\  real :: x
        \\end function
        \\subroutine t(a, b, *)
        \\  integer :: a, b
        \\end subroutine
        \\
    );
    defer w.deinit();
    try expectAll(try collect(w, "a.f90", "duplicate-dummy"), &.{
        "1: Dummy argument a is named twice",
        "5: Dummy argument X is named twice",
    });
}

const kinds =
    \\program p
    \\  implicit none
    \\  real(kind=3) :: a
    \\  integer(kind=3) :: b
    \\  real(5) :: c
    \\  real(kind=16) :: d
    \\  integer(kind=16) :: e
    \\  logical(kind=7) :: f
    \\  character(len=3, kind=3) :: g
    \\  real(kind=wp) :: h
    \\  real(kind=8) :: ok
    \\  real(10) :: ten
    \\end program
    \\
;

test "a kind that no compiler has, in the neutral dialect" {
    const w = try workspace("neutral", kinds);
    defer w.deinit();
    try expectAll(try collect(w, "a.f90", "bad-kind"), &.{
        "4: INTEGER(KIND=3) is not a supported type",
        "5: REAL(KIND=5) is not a supported type",
        "8: LOGICAL(KIND=7) is not a supported type",
        "9: CHARACTER(KIND=3) is not a supported type",
    });
}

test "kinds per compiler: REAL(3) is gfortran's and ifx's error, not Flang's" {
    const gf = try workspace("gfortran", kinds);
    defer gf.deinit();
    try expectAll(try collect(gf, "a.f90", "bad-kind"), &.{
        "3: REAL(KIND=3) is not a supported type",
        "4: INTEGER(KIND=3) is not a supported type",
        "5: REAL(KIND=5) is not a supported type",
        "8: LOGICAL(KIND=7) is not a supported type",
        "9: CHARACTER(KIND=3) is not a supported type",
    });
    const fl = try workspace("flang", kinds);
    defer fl.deinit();
    try expectAll(try collect(fl, "a.f90", "bad-kind"), &.{
        "4: INTEGER(KIND=3) is not a supported type",
        "5: REAL(KIND=5) is not a supported type",
        "8: LOGICAL(KIND=7) is not a supported type",
        "9: CHARACTER(KIND=3) is not a supported type",
    });
    const ifx = try workspace("ifx", kinds);
    defer ifx.deinit();
    try expectAll(try collect(ifx, "a.f90", "bad-kind"), &.{
        "3: REAL(KIND=3) is not a supported type",
        "4: INTEGER(KIND=3) is not a supported type",
        "5: REAL(KIND=5) is not a supported type",
        "7: INTEGER(KIND=16) is not a supported type",
        "8: LOGICAL(KIND=7) is not a supported type",
        "9: CHARACTER(KIND=3) is not a supported type",
        "12: REAL(KIND=10) is not a supported type",
    });
}

test "an INTENT outside the argument list: gfortran and ifx report it, neutral and Flang do not" {
    const text = "subroutine t(x)\n  implicit none\n  integer, intent(in) :: x, y\nend subroutine\n";
    inline for ([_][]const u8{ "neutral", "gfortran", "ifx", "flang" }) |d| {
        const w = try workspace(d, text);
        defer w.deinit();
        const got = try collect(w, "a.f90", "intent-not-in-arguments");
        if (comptime std.mem.eql(u8, d, "flang") or std.mem.eql(u8, d, "neutral")) {
            try expectAll(got, &.{});
        } else try expectAll(got, &.{"3: Variable \"y\" with INTENT keyword not found in argument list"});
    }
}
