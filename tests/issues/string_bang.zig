//! A `!` inside a string of a declaration is no comment: the declarators
//! after it stay (#842). The programs are accepted by gfortran, Flang and ifx.

const h = @import("harness.zig");

const form0 =
    \\program p
    \\  implicit none
    \\  character(len=*), parameter :: a = "x!y", b = "z"
    \\  print *, a, b
    \\end program
    \\
;

const form1 =
    \\program p
    \\  implicit none
    \\  character(len=*), parameter :: a = 'x!y', b = 'z'
    \\  character, parameter :: c*(*) = "x!y", d*(*) = "z"
    \\  print *, a, b, c, d
    \\end program
    \\
;

const form2 =
    \\program p
    \\  implicit none
    \\  character(len=5) :: a = "x!y", b
    \\  b = a
    \\end program
    \\
;

const form3 =
    \\program p
    \\  implicit none
    \\  character(len=*), parameter :: arr(2) = ["a!b", "c!d"], brr(1) = ["q"]
    \\  print *, arr, brr
    \\end program
    \\
;

const form4 =
    \\program p
    \\  implicit none
    \\  character :: g = "a", s = "!", h = "k"
    \\  print *, g, s, h
    \\end program
    \\
;

const form5 =
    \\program p
    \\  implicit none
    \\  character,parameter :: &
    \\   & punc*(*) = "!""#", &
    \\   & blank*(*) = ' '
    \\  print *, punc, blank
    \\end program
    \\
;

const form6 =
    \\program p
    \\  implicit none
    \\  character(len=3) :: a = "x!y", b = "q" ! a real comment, b = "z"
    \\  print *, a, b
    \\end program
    \\
;

test "a ! inside a string of a declaration does not drop the declarators after it (#842)" {
    inline for ([_][]const u8{ form0, form1, form2, form3, form4, form5, form6 }) |text| {
        const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text = text }}, .{});
        defer w.deinit();
        try w.expectNoDiagnostics("t.f90");
    }
}
