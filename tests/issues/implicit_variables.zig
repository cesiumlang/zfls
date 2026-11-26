//! Implicitly typed variables: the first use is the definition; references
//! and rename cover the uses in the scope and in nested scopes that use the
//! host's (#849).

const std = @import("std");
const h = @import("harness.zig");

test "an implicitly typed variable: definition, references and rename" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\program p
        \\  k = 2
        \\  m = k + 1
        \\  print *, k, m, 'k'  ! k
        \\  call inner
        \\contains
        \\  subroutine inner
        \\    k = k + 1
        \\    z = 1.0
        \\    print *, z
        \\  end subroutine inner
        \\  subroutine other
        \\    z = 2.0
        \\    print *, z
        \\  end subroutine other
        \\end program p
        \\
    }}, .{});
    defer w.deinit();
    // go to definition of a use is the first use
    const def = (try w.definition("a.f90", w.pos("a.f90", "k + 1", 0, 0))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), def.line);
    try std.testing.expectEqual(@as(i64, 2), def.col);
    // the host's k and the internal procedure's use of it: five places, not
    // the string or the comment
    const refs = try w.references("a.f90", w.pos("a.f90", "k = 2", 0, 0));
    try std.testing.expectEqual(@as(usize, 5), refs.len);
    // m is used twice
    try std.testing.expectEqual(@as(usize, 2), (try w.references("a.f90", w.pos("a.f90", "m = ", 0, 0))).len);
    // z of the two internal procedures are two variables
    try std.testing.expectEqual(@as(usize, 2), (try w.references("a.f90", w.pos("a.f90", "z = 1.0", 0, 0))).len);
    const edits = try w.rename("a.f90", w.pos("a.f90", "k = 2", 0, 0), "kk");
    try std.testing.expectEqual(@as(usize, 5), edits.len);
    // a name another variable has is refused
    try std.testing.expectEqual(@as(usize, 0), (try w.rename("a.f90", w.pos("a.f90", "k = 2", 0, 0), "m")).len);
}

test "implicit typing off: IMPLICIT NONE leaves a name with no definition" {
    const w = try h.Workspace.init(&.{.{ .name = "b.f90", .text =
        \\program q
        \\  implicit none
        \\  integer :: i
        \\  i = 1
        \\  j = i
        \\end program q
        \\
    }}, .{});
    defer w.deinit();
    try std.testing.expect((try w.definition("b.f90", w.pos("b.f90", "j = i", 0, 0))) == null);
    try std.testing.expectEqual(@as(usize, 0), (try w.rename("b.f90", w.pos("b.f90", "j = i", 0, 0), "jj")).len);
    // a declared variable is as before
    try std.testing.expectEqual(@as(usize, 3), (try w.references("b.f90", w.pos("b.f90", "i = 1", 0, 0))).len);
}

test "implicit typing in fixed form with IMPLICIT ranges" {
    const w = try h.Workspace.init(&.{.{ .name = "f.f", .text =
        \\      subroutine s(n)
        \\      implicit double precision (a-h, o-z)
        \\      do 10 i = 1, n
        \\         x = x + i
        \\   10 continue
        \\      y = x
        \\      end
        \\
    }}, .{});
    defer w.deinit();
    const def = (try w.definition("f.f", w.pos("f.f", "y = x", 0, 4))) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 3), def.line);
    try std.testing.expectEqual(@as(i64, 9), def.col);
    try std.testing.expectEqual(@as(usize, 3), (try w.references("f.f", w.pos("f.f", "y = x", 0, 4))).len);
    // the loop variable: two uses, not the label
    try std.testing.expectEqual(@as(usize, 2), (try w.references("f.f", w.pos("f.f", "i = 1", 0, 0))).len);
}

test "kind parameters of a type spec and a literal are no implicit variables" {
    const w = try h.Workspace.init(&.{.{ .name = "k.f90", .text =
        \\subroutine s
        \\  complex(kk) z
        \\  z = 2.0_kk
        \\end subroutine s
        \\
    }}, .{});
    defer w.deinit();
    try std.testing.expect((try w.definition("k.f90", w.pos("k.f90", "kk)", 0, 0))) == null);
    try std.testing.expect((try w.definition("k.f90", w.pos("k.f90", "_kk", 0, 1))) == null);
}
