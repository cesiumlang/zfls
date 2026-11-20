//! Intel's conditional compilation directives (#274): `!DEC$ IF DEFINED
//! (sym)`, `!DIR$ IF (expr)`, `ELSEIF`, `ELSE`, `ENDIF`, `DEFINE` and
//! `UNDEFINE`, which the compiler honors in every Fortran file.

const std = @import("std");
const h = @import("harness.zig");

const unicode = [_]h.File{.{ .name = "m.f90", .text =
    \\module m
    \\   implicit none
    \\!DEC$ IF DEFINED (_UNICODE)
    \\   integer, parameter :: utf16 = 1
    \\!DEC$ ELSE
    \\   integer, parameter :: utf16 = 0
    \\!DEC$ ENDIF
    \\!DIR$ IF DEFINED (DBG)
    \\   integer :: lvl
    \\!DIR$ ELSE
    \\   real :: lvl
    \\!DIR$ ENDIF
    \\end module
    \\
}};

fn expectBranches(w: *h.Workspace) !void {
    try w.open("m.f90", "fortran");
    try w.expectNoDiagnostics("m.f90");
    try w.expectHoverContains("m.f90", w.pos("m.f90", "lvl", 1, 0), "REAL :: lvl");
    try w.expectHoverContains("m.f90", w.pos("m.f90", "utf16 = 0", 0, 0), "utf16 = 0");
}

test "FL #309 the branches that Intel's !DEC$ IF and !DIR$ IF leave out are skipped (#274)" {
    const w = try h.Workspace.init(&unicode, .{});
    defer w.deinit();
    try h.check(309, .fixed, expectBranches(w));
}

test "pp_defs define the symbols of !DIR$ IF DEFINED (#274)" {
    const w = try h.Workspace.init(&unicode, .{ .pp_defs = &.{.{ .name = "DBG", .value = "" }} });
    defer w.deinit();
    try w.open("m.f90", "fortran");
    try w.expectNoDiagnostics("m.f90");
    try w.expectHoverContains("m.f90", w.pos("m.f90", "lvl", 0, 0), "INTEGER :: lvl");
}

test "the branches left out are inactive: comment tokens, and they fold (#274)" {
    const w = try h.Workspace.init(&unicode, .{});
    defer w.deinit();
    try w.open("m.f90", "fortran");
    var inactive = false;
    for (try w.semanticTokens("m.f90")) |t| {
        if (t.line == 3) try std.testing.expectEqualStrings("comment", t.type);
        if (t.line == 3) inactive = true;
        // the branch read has its variable
        if (t.line == 10 and std.mem.eql(u8, t.text, "lvl")) try std.testing.expectEqualStrings("variable", t.type);
    }
    try std.testing.expect(inactive);
    var folds: usize = 0;
    for (try w.foldingRanges("m.f90")) |f| {
        if ((f.start == 2 and f.end == 3) or (f.start == 4 and f.end == 5) or (f.start == 7 and f.end == 8) or (f.start == 9 and f.end == 10)) folds += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), folds);
}

test "DEFINE, UNDEFINE, nested IFs, ELSEIF and Fortran operators (#274)" {
    const files = [_]h.File{.{ .name = "d.f90", .text =
        \\subroutine s()
        \\   implicit none
        \\!DEC$ DEFINE X
        \\!DEC$ IF DEFINED(X)
        \\   integer :: a
        \\!DEC$ ELSE
        \\   real :: a
        \\!DEC$ ENDIF
        \\!DEC$ UNDEFINE X
        \\!DEC$ IF DEFINED(X)
        \\   integer :: b
        \\!DEC$ ELSE
        \\   real :: b
        \\!DEC$ ENDIF
        \\!DEC$ DEFINE VER = 3
        \\!DIR$ IF (VER .GE. 2 .AND. .NOT. DEFINED(OLD))
        \\!DIR$   IF (VER .EQ. 2)
        \\   integer :: c
        \\!DIR$   ELSEIF (VER == 3)
        \\   complex :: c
        \\!DIR$   ELSE
        \\   real :: c
        \\!DIR$   ENDIF
        \\!DIR$ ELSE
        \\   logical :: c
        \\!DIR$ ENDIF
        \\   a = 1
        \\   b = 2
        \\   c = 3
        \\end subroutine s
        \\
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("d.f90", "fortran");
    try w.expectNoDiagnostics("d.f90");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "a = 1", 0, 0), "INTEGER :: a");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "b = 2", 0, 0), "REAL :: b");
    try w.expectHoverContains("d.f90", w.pos("d.f90", "c = 3", 0, 0), "COMPLEX :: c");
}

test "fixed form: CDEC$ IF (#274)" {
    const files = [_]h.File{.{ .name = "f.f", .text =
        \\      subroutine s()
        \\      implicit none
        \\CDEC$ IF DEFINED(WIDE)
        \\      integer*8 n
        \\CDEC$ ELSE
        \\      integer n
        \\CDEC$ ENDIF
        \\      n = 1
        \\      end
        \\
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("f.f", "fortran");
    try w.expectNoDiagnostics("f.f");
    const hover = (try w.hover("f.f", w.pos("f.f", "n = 1", 0, 0))) orelse return error.NoHover;
    try std.testing.expect(std.mem.find(u8, hover, "INTEGER :: n") != null);
}

test "after the C preprocessor, in a preprocessed file (#274)" {
    const files = [_]h.File{.{ .name = "p.F90", .text =
        \\subroutine s()
        \\   implicit none
        \\#ifdef CPPX
        \\!DEC$ DEFINE Y
        \\#endif
        \\!DEC$ IF DEFINED(Y)
        \\   integer :: k
        \\!DEC$ ELSE
        \\   real :: k
        \\!DEC$ ENDIF
        \\   k = 1
        \\end subroutine s
        \\
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("p.F90", "fortran");
    try w.expectNoDiagnostics("p.F90");
    try w.expectHoverContains("p.F90", w.pos("p.F90", "k = 1", 0, 0), "REAL :: k");
}

test "other !DIR$ directives are untouched (#274)" {
    const files = [_]h.File{.{ .name = "o.f90", .text =
        \\subroutine s(x)
        \\   implicit none
        \\!DIR$ ATTRIBUTES DLLEXPORT :: s
        \\   real, intent(inout) :: x(10)
        \\   integer :: i
        \\!DIR$ IVDEP
        \\   do i = 1, 10
        \\      x(i) = 0
        \\   end do
        \\end subroutine s
        \\
    }};
    const w = try h.Workspace.init(&files, .{});
    defer w.deinit();
    try w.open("o.f90", "fortran");
    try w.expectNoDiagnostics("o.f90");
    try w.expectHoverContains("o.f90", w.pos("o.f90", "x(i)", 0, 0), "REAL, INTENT(INOUT), DIMENSION(10) :: x");
}

test "with disable_intel_directives, every branch is read (#274)" {
    const w = try h.Workspace.init(&unicode, .{ .settings = .{ .disable_intel_directives = true } });
    defer w.deinit();
    try w.open("m.f90", "fortran");
    var twice: usize = 0;
    for (try w.diagnostics("m.f90")) |d| {
        if (std.mem.find(u8, d.message, "declared twice") != null) twice += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), twice);
}
