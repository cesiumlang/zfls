//! Upstream issues about hover, go to definition / implementation and
//! signature help.

const std = @import("std");
const h = @import("harness.zig");

test "#483 hover on a call keeps the interface when the procedure is declared external" {
    const w = try h.Workspace.init(&.{
        .{ .name = "lapack.f90", .text =
        \\subroutine dgesv(n, nrhs)
        \\  integer, intent(in) :: n, nrhs
        \\end subroutine dgesv
        \\
        },
        .{ .name = "plain.f90", .text =
        \\module plain
        \\contains
        \\  subroutine step()
        \\    implicit none
        \\    call dgesv(1, 1)
        \\  end subroutine step
        \\end module plain
        \\
        },
        .{ .name = "ext.f90", .text =
        \\module ext
        \\contains
        \\  subroutine step()
        \\    implicit none(type, external)
        \\    external dgesv
        \\    call dgesv(1, 1)
        \\  end subroutine step
        \\end module ext
        \\
        },
    }, .{});
    defer w.deinit();
    // the control: without the EXTERNAL statement
    try w.expectHoverContains("plain.f90", w.pos("plain.f90", "dgesv", 0, 1), "dgesv");
    const call = w.pos("ext.f90", "call dgesv", 0, 6);
    try h.check(483, .fixed, w.expectHoverContains("ext.f90", call, "nrhs"));
}

test "#281 hover shows the documentation of a function with a type prefix" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\program main
        \\    ! type a or be here:
        \\    print*, a()
        \\    print*, b()
        \\contains
        \\
        \\function a()
        \\    !! this shoes up
        \\    logical a
        \\    a = .true.
        \\end function
        \\
        \\logical function b()
        \\    !! this doesn't
        \\    b = .false.
        \\end function
        \\
        \\end program main
        \\
        ,
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "a()", 0, 0), "this shoes up");
    try h.check(281, .fixed, w.expectHoverContains("t.f90", w.pos("t.f90", "b()", 0, 0), "this doesn't"));
}

test "#237 a Doxygen comment above an expression is not the documentation of a later procedure" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\subroutine sub_before
        \\    integer :: i
        \\
        \\    !> Trying to add a docstring to an expression
        \\    i = 1
        \\end subroutine
        \\
        \\subroutine sub_no_doc
        \\end subroutine
        \\
        \\program p
        \\    call sub_no_doc
        \\end program p
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(237, .fixed, notContains(w, "t.f90", w.pos("t.f90", "call sub_no_doc", 0, 6), "Trying to add"));
}

fn notContains(w: *h.Workspace, name: []const u8, p: h.Pos, fragment: []const u8) !void {
    const text = (try w.hover(name, p)) orelse return;
    if (std.mem.indexOf(u8, text, fragment) != null) return h.unmet("hover contains '{s}': {s}", .{ fragment, text });
}

test "#237 documentation still attaches to a variable and to a procedure (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\    !> The counter
        \\    integer :: counter
        \\contains
        \\    !> Adds one
        \\    subroutine bump()
        \\        counter = counter + 1
        \\    end subroutine bump
        \\end module m
        \\
        \\program p
        \\    use m
        \\    call bump()
        \\    counter = 0
        \\end program p
        \\
        ,
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "counter = 0", 0, 1), "The counter");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "call bump", 0, 6), "Adds one");
}

test "#483 an EXTERNAL name without a procedure still hovers as external (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\subroutine caller()
        \\    external unknown_proc
        \\    call unknown_proc(1)
        \\end subroutine caller
        \\
        ,
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "call unknown_proc", 0, 6), "EXTERNAL");
}

test "#124 hover on a parameter shows a value that is a function call" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\    integer, parameter :: sp = selected_real_kind(6)
        \\    real(sp) :: x
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(124, .fixed, w.expectHoverContains("t.f90", w.pos("t.f90", "real(sp)", 0, 5), "selected_real_kind(6)"));
}

test "#118 hover on a fixed-form function that the caller declares with a type" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f",
        .text =
        \\      function fff(x,y)
        \\          implicit none
        \\          real fff, x,y
        \\          fff = x+y
        \\          return
        \\      end
        \\
        \\      program main
        \\          implicit none
        \\          real y, fff
        \\          y = fff(1.2,3.3)
        \\          write(*,*) y
        \\      end
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(118, .fixed, w.expectHoverContains("t.f", w.pos("t.f", "fff(1.2", 0, 1), "FUNCTION"));
}

test "#108 hover on an ASSOCIATE name bound to an array slice shows the slice's shape" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\PROGRAM test_associate_block
        \\    IMPLICIT NONE
        \\    REAL :: A(5), B(5,5), C, III = 1
        \\    ASSOCIATE (ARRAY => B(:,1))
        \\        ARRAY (3) = ARRAY (1) + ARRAY (2)
        \\    END ASSOCIATE
        \\END PROGRAM test_associate_block
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(108, .fixed, notContains(w, "t.f90", w.pos("t.f90", "ARRAY (3)", 0, 1), "(5,5)"));
}

test "#23 go to implementation from an EXTERNAL statement reaches the procedure" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\program main
        \\    external sub1
        \\    integer,external :: fun1
        \\    call bill(sub1,fun1)
        \\end program
        \\subroutine bill(proc,fun)
        \\    integer :: fun,i
        \\    i=fun()
        \\    call proc(i)
        \\end subroutine
        \\subroutine sub1(i)
        \\    integer :: i
        \\    write(*,*) i
        \\end subroutine
        \\function fun1()
        \\    integer :: fun1
        \\    fun1 = 1
        \\end function
        \\
        ,
    }}, .{});
    defer w.deinit();
    const impl = try w.implementation("t.f90", w.pos("t.f90", "sub1", 0, 1));
    const want = w.pos("t.f90", "subroutine sub1", 0, 0).line;
    try h.check(23, .fixed, blk: {
        const l = impl orelse break :blk h.unmet("no implementation found for sub1", .{});
        break :blk h.expect(l.line == want, "implementation at line {d}, expected {d}", .{ l.line + 1, want + 1 });
    });
}

test "#87 signature help counts the commas of the call, not those inside an argument" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\contains
        \\  subroutine foo(arg1, arg2, arg3)
        \\    implicit none
        \\    integer(4), intent(in) :: arg1, arg2, arg3
        \\  end subroutine foo
        \\
        \\  subroutine bar()
        \\    implicit none
        \\    integer(4) :: arr(4, 4)
        \\    arr = 0
        \\    call foo(arr(2, 3), 1, 2)
        \\  end subroutine bar
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    const sig = (try w.signature("t.f90", w.pos("t.f90", "arr(2, 3), 1", 0, 11))) orelse
        return h.check(87, .fixed, h.unmet("no signature help", .{}));
    try h.check(87, .fixed, h.expect(sig.active == 1, "active parameter {d}, expected 1", .{sig.active}));
}

test "#203 several PARAMETER names with their values (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\program p
        \\  implicit none
        \\  integer n, m
        \\  parameter (n = 5, m = n * 2)
        \\  print *, n, m
        \\end program p
        \\
        ,
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "print *, n, m", 0, 9), "PARAMETER :: n = 5");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "print *, n, m", 0, 12), "PARAMETER :: m = n * 2");
}

test "#108 an ASSOCIATE name bound to an element or a 2-D section (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\PROGRAM p
        \\    REAL :: B(5,5), C(4,4,4)
        \\    ASSOCIATE (ELEM => B(2,3), PLANE => C(:,:,1), WHOLE => B)
        \\        ELEM = PLANE(1,1) + WHOLE(1,1)
        \\    END ASSOCIATE
        \\END PROGRAM p
        \\
        ,
    }}, .{});
    defer w.deinit();
    const elem = (try w.hover("t.f90", w.pos("t.f90", "ELEM = PLANE", 0, 1))) orelse return h.check(108, .fixed, h.unmet("no hover for ELEM", .{}));
    try h.expect(std.mem.indexOf(u8, elem, "DIMENSION") == null, "an element is a scalar: {s}", .{elem});
    try w.expectHoverContains("t.f90", w.pos("t.f90", "PLANE(1,1)", 0, 1), "DIMENSION(:,:)");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "WHOLE(1,1)", 0, 1), "DIMENSION(5,5)");
}

test "#118 a real array that is indexed is not mistaken for a function (control)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\function fff(x)
        \\    real fff, x
        \\    fff = x
        \\end function
        \\
        \\program main
        \\    real fff(3)
        \\    fff(1) = 1.0
        \\end program main
        \\
        ,
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "fff(1) = 1.0", 0, 1), "DIMENSION(3)");
}

test "#203 the PARAMETER statement makes a constant" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\program p
        \\  implicit none
        \\  integer n
        \\  parameter (n = 5)
        \\  print *, n
        \\end program p
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(203, .fixed, w.expectHoverContains("t.f90", w.pos("t.f90", "print *, n", 0, 9), "PARAMETER"));
}

test "#498 an include next to the file, a missing one, and a cursor off the name (control)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "a.F90", .text =
        \\program a
        \\#include "local.inc"
        \\#include "missing.inc"
        \\end program a
        \\
        },
        .{ .name = "local.inc", .text =
        \\integer :: x
        \\
        },
    }, .{});
    defer w.deinit();
    const def = (try w.definition("a.F90", w.pos("a.F90", "local.inc", 0, 2))) orelse
        return h.check(498, .fixed, h.unmet("the include next to the file is not found", .{}));
    try h.expect(std.mem.endsWith(u8, def.uri, "local.inc"), "definition is {s}", .{def.uri});
    try h.expect((try w.definition("a.F90", w.pos("a.F90", "missing.inc", 0, 2))) == null, "a missing include has a definition", .{});
    try h.expect((try w.definition("a.F90", w.pos("a.F90", "#include \"local", 0, 3))) == null, "the directive word has a definition", .{});
}

test "#498 go to definition on an include directive opens the included file" {
    const w = try h.Workspace.init(&.{
        .{ .name = ".fortlsrc", .text =
        \\{
        \\  "source_dirs": ["./**"],
        \\  "incl_suffixes": ["inc"],
        \\  "pp_suffixes": ["inc"],
        \\  "include_dirs": ["include", "src"]
        \\}
        \\
        },
        .{ .name = "src/a.F90", .text =
        \\program a
        \\#include "sample.inc"
        \\end program a
        \\
        },
        .{ .name = "include/sample.inc", .text =
        \\integer :: from_include
        \\
        },
    }, .{});
    defer w.deinit();
    const def = try w.definition("src/a.F90", w.pos("src/a.F90", "sample.inc", 0, 2));
    try h.check(498, .fixed, blk: {
        const l = def orelse break :blk h.unmet("no definition for the include", .{});
        break :blk h.expect(std.mem.endsWith(u8, l.uri, "sample.inc"), "definition is {s}", .{l.uri});
    });
}

test "#478 a Markdown list in a parameter's documentation does not indent the next parameter" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\contains
        \\  !> Does things
        \\  subroutine foo(bar, baz)
        \\    integer, intent(in) :: bar !! bar is a place you drink:
        \\    !! - pub
        \\    !! - cafe
        \\    integer, intent(in) :: baz !! baz is a nonsense word
        \\  end subroutine foo
        \\end module m
        \\program p
        \\  use m
        \\  call foo(1, 2)
        \\end program p
        \\
        ,
    }}, .{});
    defer w.deinit();
    // a blank line ends the list, so `baz` is not a continuation of its last item
    try h.check(478, .fixed, w.expectHoverContains("t.f90", w.pos("t.f90", "foo(1, 2)", 0, 1), "\n\n`baz`"));
}

test "hansec #168 references to a separate module procedure include its implementation in a submodule" {
    const w = try h.Workspace.init(&.{
        .{ .name = "mod.f90", .text =
        \\module test_module
        \\    implicit none
        \\    interface
        \\        module subroutine test_subroutine()
        \\        end subroutine
        \\        module subroutine other()
        \\        end subroutine
        \\    end interface
        \\end module test_module
        \\
        },
        .{ .name = "smod.f90", .text =
        \\submodule(test_module) test_submodule
        \\contains
        \\module subroutine test_subroutine()
        \\end subroutine
        \\module procedure other
        \\end procedure
        \\end
        \\
        },
        .{ .name = "prog.f90", .text =
        \\program p
        \\    use test_module
        \\    call test_subroutine()
        \\end program p
        \\
        },
    }, .{});
    defer w.deinit();
    const Case = struct { file: []const u8, needle: []const u8 };
    const outcome: anyerror!void = blk: {
        for ([_][]const u8{ "test_subroutine", "other" }) |name| {
            const iface = w.pos("mod.f90", name, 0, 1);
            const impl = w.pos("smod.f90", name, 0, 1);
            // from the interface, from the implementation
            for ([_]Case{ .{ .file = "mod.f90", .needle = name }, .{ .file = "smod.f90", .needle = name } }) |c| {
                const refs = try w.references(c.file, w.pos(c.file, c.needle, 0, 1));
                var has_iface = false;
                var has_impl = false;
                for (refs) |r| {
                    if (std.mem.endsWith(u8, r.uri, "mod.f90") and !std.mem.endsWith(u8, r.uri, "smod.f90") and r.line == iface.line) has_iface = true;
                    if (std.mem.endsWith(u8, r.uri, "smod.f90") and r.line == impl.line) has_impl = true;
                }
                if (!has_iface or !has_impl) break :blk h.unmet("references to {s} from {s}: interface {}, implementation {} ({d} references)", .{ name, c.file, has_iface, has_impl, refs.len });
            }
        }
        // a rename from the interface renames the implementation too
        var renames_impl = false;
        for (try w.rename("mod.f90", w.pos("mod.f90", "other", 0, 1), "renamed")) |e| {
            if (std.mem.endsWith(u8, e.uri, "smod.f90")) renames_impl = true;
        }
        if (!renames_impl) break :blk h.unmet("renaming the interface does not rename the implementation", .{});
        // the call still counts
        const refs = try w.references("mod.f90", w.pos("mod.f90", "test_subroutine", 0, 1));
        for (refs) |r| if (std.mem.endsWith(u8, r.uri, "prog.f90")) break :blk {};
        break :blk h.unmet("the call is not a reference", .{});
    };
    try h.checkIn(.hansec, 168, .fixed, outcome);
}

const rename_fixture = [_]h.File{.{
    .name = "t.f90",
    .text =
    \\module m
    \\contains
    \\  function func_1(x)
    \\    integer :: x, func_1
    \\    func_1 = x
    \\  end function func_1
    \\end module m
    \\program p
    \\  use m, func_1_ref => func_1
    \\  logical :: func_1
    \\  print *, func_1_ref(3), func_1
    \\end program p
    \\
    ,
}};

test "hansec #137 the original name on a USE rename line is the module's entity" {
    const w = try h.Workspace.init(&rename_fixture, .{});
    defer w.deinit();
    const def = try w.definition("t.f90", w.pos("t.f90", "=> func_1", 0, 4));
    try h.checkIn(.hansec, 137, .fixed, blk: {
        const l = def orelse break :blk h.unmet("no definition for the original name", .{});
        break :blk h.expect(l.line == 2, "definition at line {d}, expected the function at line 3", .{l.line + 1});
    });
}

test "a rename without ONLY makes the local name the module's entity, and hides the original name" {
    const w = try h.Workspace.init(&rename_fixture, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f90", w.pos("t.f90", "func_1_ref(3)", 0, 1), "FUNCTION");
    try w.expectHoverContains("t.f90", w.pos("t.f90", "func_1_ref =>", 0, 1), "FUNCTION");
    // the local variable of the same name as the original is not the function
    try w.expectHoverContains("t.f90", w.pos("t.f90", "(3), func_1", 0, 6), "LOGICAL");
}

test "#534 fixed-form documentation comments do not keep the indentation of the code" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f",
        .text =
        \\      SUBROUTINE MYFUNC(PARAM1)
        \\      !> THIS IS AN EXAMPLE FUNCTION TO DEMONSTRATE
        \\      !! THE BROKEN PARSING OF
        \\      !! DOCSTRINGS FOR FIXED FORMAT CODE
        \\
        \\      REAL, INTENT(IN) :: PARAM1
        \\      !> THE SAME PROBLEM OCCURS
        \\      !! FOR DOCSTRINGS FOR PARAMETERS
        \\
        \\      END SUBROUTINE MYFUNC
        \\
        ,
    }}, .{});
    defer w.deinit();
    const outcome: anyerror!void = blk: {
        // `!>` documents the next object, PARAM1; its continuation lines are
        // not indented by the six columns of fixed form (a Markdown code block)
        const param = (try w.hover("t.f", w.pos("t.f", "PARAM1", 1, 1))) orelse break :blk h.unmet("no hover on PARAM1", .{});
        const docs = param[(std.mem.indexOf(u8, param, "-----") orelse break :blk h.unmet("no documentation: {s}", .{param}))..];
        if (std.mem.indexOf(u8, docs, "\n ") != null) break :blk h.unmet("an indented line in the documentation: {s}", .{docs});
        break :blk h.expect(std.mem.indexOf(u8, docs, "DEMONSTRATE\nTHE BROKEN PARSING OF\nDOCSTRINGS FOR FIXED FORMAT CODE") != null, "hover of PARAM1: {s}", .{param});
    };
    try h.check(534, .fixed, outcome);
}

test "#481 an #include path with slashes is found in the include directories" {
    const w = try h.Workspace.init(&.{
        .{ .name = ".fortlsrc", .text =
        \\{"source_dirs": ["./**"], "include_dirs": ["include"]}
        \\
        },
        .{ .name = "src/main.F90", .text =
        \\program p
        \\#include "petsc/finclude/petscvec.h"
        \\#ifdef PETSC_HAVE_VEC
        \\  integer :: from_vec
        \\#endif
        \\  from_vec = 1
        \\end program p
        \\
        },
        .{ .name = "include/petsc/finclude/petscvec.h", .text =
        \\#define PETSC_HAVE_VEC
        \\
        },
    }, .{});
    defer w.deinit();
    const outcome: anyerror!void = blk: {
        // the macro of the header is defined
        w.expectHoverContains("src/main.F90", w.pos("src/main.F90", "from_vec = 1", 0, 1), "INTEGER :: from_vec") catch |e| break :blk e;
        const def = (try w.definition("src/main.F90", w.pos("src/main.F90", "finclude", 0, 1))) orelse
            break :blk h.unmet("no definition for the include", .{});
        break :blk h.expect(std.mem.endsWith(u8, def.uri, "petsc/finclude/petscvec.h"), "definition is {s}", .{def.uri});
    };
    try h.check(481, .fixed, outcome);
}

test "hansec #178 signature help skips array constructors and nested calls" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\contains
        \\  subroutine mysub(a, b, c, d, e)
        \\    integer, intent(in) :: a, b(:), c, d, e
        \\  end subroutine mysub
        \\  integer function myfun(a, b, c, d, e)
        \\    integer, intent(in) :: a, b, c, d, e
        \\    myfun = a
        \\  end function myfun
        \\  subroutine caller(a, b, c, d, e)
        \\    integer, intent(in) :: a, b, c, d, e
        \\    integer :: x
        \\    call mysub(a, [1, 2, 3], c, d, e)
        \\    call mysub(a, (/1, 2, 3/), c, d, e)
        \\    x = myfun(a, myfun(a, b, c, d, e), c, d, e)
        \\  end subroutine caller
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    const outcome: anyerror!void = blk: {
        // just after the third argument, `c`
        for ([_][]const u8{ "[1, 2, 3], c", "(/1, 2, 3/), c", "d, e), c" }) |needle| {
            const sig = (try w.signature("t.f90", w.pos("t.f90", needle, 0, needle.len))) orelse
                break :blk h.unmet("no signature help after '{s}'", .{needle});
            if (sig.active != 2) break :blk h.unmet("after '{s}': active parameter {d}, expected 2", .{ needle, sig.active });
        }
    };
    try h.checkIn(.hansec, 178, .fixed, outcome);
}

test "hansec #229 an ASSOCIATE opened on the line of its DO: names inside are found" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\program p
        \\  implicit none
        \\  integer :: i
        \\  real :: arr(3)
        \\  do i=1,size(arr); associate(point => arr(i))
        \\    point = 1.0
        \\  end associate; end do
        \\end program p
        \\
        ,
    }}, .{});
    defer w.deinit();
    // the innermost of the scopes that open on the same line is the ASSOCIATE
    try h.checkIn(.hansec, 229, .fixed, blk: {
        w.expectHoverContains("t.f90", w.pos("t.f90", "point = 1.0", 0, 1), "REAL :: point") catch |e| break :blk e;
        const def = (try w.definition("t.f90", w.pos("t.f90", "point = 1.0", 0, 1))) orelse break :blk h.unmet("no definition for point", .{});
        break :blk h.expect(def.line == 4, "definition of point at line {d}", .{def.line + 1});
    });
}
