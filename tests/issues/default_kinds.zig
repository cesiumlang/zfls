//! The default kinds of a file's compiler options (`-fdefault-real-8`,
//! `/real-size:64`, ...) and of Intel's `!DEC$ REAL:n` in the argument
//! checks (#512; the audits, #488, #489).

const std = @import("std");
const h = @import("harness.zig");

const kinds = h.File{ .name = "kinds.f90", .text =
    \\module kinds8
    \\  implicit none
    \\contains
    \\  subroutine take8(x, n)
    \\    real(8), intent(in) :: x
    \\    integer(8), intent(in) :: n
    \\    print *, x, n
    \\  end subroutine take8
    \\  subroutine take16(d)
    \\    real(16), intent(in) :: d
    \\    print *, d
    \\  end subroutine take16
    \\end module kinds8
    \\program kinds
    \\  use kinds8
    \\  implicit none
    \\  real :: r
    \\  integer :: i
    \\  double precision :: d
    \\  r = 1.0
    \\  i = 2
    \\  d = 3.0d0
    \\  call take8(r, i)
    \\  call take8(1.0, 2)
    \\  call take16(d)
    \\end program kinds
    \\
};

/// The errors of `kinds.f90` checked with the gfortran command `args`
fn kindsErrors(comptime args: []const u8) !usize {
    const db = h.File{ .name = "compile_commands.json", .text = "[{\"directory\": \".\", \"file\": \"kinds.f90\", \"command\": \"gfortran " ++ args ++ " -c kinds.f90\"}]\n" };
    const w = try h.Workspace.init(&.{ db, kinds }, .{});
    defer w.deinit();
    var n: usize = 0;
    for (try w.diagnostics("kinds.f90")) |d| if (d.severity == 1) {
        n += 1;
    };
    return n;
}

test "gfortran's -fdefault-real-8, -fdefault-integer-8 and -fdefault-double-8" {
    // gfortran: none of the three calls is an error with the first two;
    // with -fdefault-double-8, take16(d) is (`passed REAL(8) to REAL(16)`)
    try h.expect(try kindsErrors("-fdefault-real-8 -fdefault-integer-8") == 0, "errors with -fdefault-real-8 -fdefault-integer-8", .{});
    try h.expect(try kindsErrors("-fdefault-real-8 -fdefault-integer-8 -fdefault-double-8") == 1, "not the one error with -fdefault-double-8", .{});
    try h.expect(try kindsErrors("-O2") == 5, "not the five errors without the options", .{});
}

test "Intel's /real-size:64 /integer-size:64" {
    // ifx: exit 0
    const db = h.File{ .name = "compile_commands.json", .text = "[{\"directory\": \".\", \"file\": \"rsize.f90\", \"command\": \"ifx /real-size:64 /integer-size:64 /c rsize.f90\"}]\n" };
    const w = try h.Workspace.init(&.{
        db,
        .{ .name = "rsize.f90", .text =
        \\module rs
        \\  implicit none
        \\contains
        \\  subroutine take8(x, n)
        \\    real(8), intent(in) :: x
        \\    integer(8), intent(in) :: n
        \\    print *, x, n
        \\  end subroutine
        \\end module
        \\program rsz
        \\  use rs
        \\  implicit none
        \\  real :: y = 1
        \\  integer :: m = 2
        \\  call take8(y, m)
        \\end program
        \\
        },
    }, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("rsize.f90");
}

test "!DEC$ REAL:8 sets the default REAL kind of the next program unit only" {
    // ifx: only `call take8(inprog)` is an error (#6633)
    const w = try h.Workspace.init(&.{.{ .name = "r8.f90", .text =
        \\module take8m
        \\contains
        \\  subroutine take8(x)
        \\    real(8), intent(in) :: x
        \\    print *, x
        \\  end subroutine take8
        \\end module take8m
        \\!DEC$ REAL:8
        \\module r8m
        \\  use take8m
        \\  real :: inmod
        \\contains
        \\  subroutine s1()
        \\    call take8(inmod)
        \\  end subroutine s1
        \\end module r8m
        \\program r8p
        \\  use take8m
        \\  real :: inprog
        \\  inprog = 1
        \\  call take8(inprog)
        \\end program r8p
        \\
    }}, .{});
    defer w.deinit();
    var lines: std.ArrayList(i64) = .empty;
    for (try w.diagnostics("r8.f90")) |d| if (d.severity == 1) try lines.append(w.a(), d.line);
    try h.expect(lines.items.len == 1 and lines.items[0] == 20, "errors on lines {any}", .{lines.items});
}
