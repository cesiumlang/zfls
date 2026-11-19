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
    if (std.mem.find(u8, text, fragment) != null) return h.unmet("hover contains '{s}': {s}", .{ fragment, text });
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
    try h.expect(std.mem.find(u8, elem, "DIMENSION") == null, "an element is a scalar: {s}", .{elem});
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

const separate_procedures = [_]h.File{
    .{ .name = "shapes.f90", .text =
    \\module shapes
    \\  implicit none
    \\  interface
    \\    module function area(r) result(a)
    \\      !! Area (interface)
    \\      real, intent(in) :: r
    \\      real :: a
    \\    end function area
    \\    module subroutine report(x)
    \\      !! Report (interface)
    \\      integer, intent(in) :: x
    \\    end subroutine report
    \\    module subroutine reset()
    \\      !! Reset (interface)
    \\    end subroutine reset
    \\  end interface
    \\end module shapes
    \\
    },
    .{ .name = "shapes_impl.f90", .text =
    \\submodule (shapes) shapes_impl
    \\contains
    \\  module function area(r) result(a)
    \\    !! Area of a circle, computed in the submodule
    \\    real, intent(in) :: r
    \\    real :: a
    \\    a = 3.14159 * r * r
    \\  end function area
    \\  module procedure report
    \\    !! Prints x, from the submodule
    \\    print *, x
    \\  end procedure report
    \\  module subroutine reset()
    \\  end subroutine reset
    \\end submodule shapes_impl
    \\
    },
    .{ .name = "main.f90", .text =
    \\program main
    \\  use shapes
    \\  print *, area(1.0)
    \\  call report(1)
    \\  call reset()
    \\end program main
    \\
    },
};

test "separate module procedures: hover and definition stay on the interface by default (fortls)" {
    const w = try h.Workspace.init(&separate_procedures, .{});
    defer w.deinit();
    const d = (try w.definition("main.f90", w.pos("main.f90", "area(1.0)", 0, 1))).?;
    try std.testing.expect(std.mem.endsWith(u8, d.uri, "/shapes.f90"));
    try w.expectHoverContains("main.f90", w.pos("main.f90", "area(1.0)", 0, 1), "Area (interface)");
}

fn expectImplementation(w: *h.Workspace, docs: bool) !void {
    for ([_][]const u8{ "area", "report", "reset" }) |name| {
        const call = w.pos("main.f90", name, 0, 1);
        const d = (try w.definition("main.f90", call)) orelse return h.unmet("no definition of {s}", .{name});
        const body = w.pos("shapes_impl.f90", name, 0, 0);
        try h.expect(std.mem.endsWith(u8, d.uri, "/shapes_impl.f90") and d.line == body.line, "definition of {s}: {s}:{d}", .{ name, d.uri, d.line });
        if (!docs) continue;
        const hv = (try w.hover("main.f90", call)) orelse return h.unmet("no hover on {s}", .{name});
        const want: []const u8 = if (std.mem.eql(u8, name, "area"))
            "computed in the submodule"
        else if (std.mem.eql(u8, name, "report"))
            "Prints x, from the submodule"
        else
            "Reset (interface)"; // the body has no documentation
        try h.expect(std.mem.find(u8, hv, want) != null, "hover on {s} lacks {s}: {s}", .{ name, want, hv });
    }
    // the signature of a MODULE PROCEDURE body comes from its interface
    const hv = (try w.hover("main.f90", w.pos("main.f90", "report", 0, 1))).?;
    try h.expect(std.mem.find(u8, hv, "report(x)") != null, "hover on report: {s}", .{hv});
}

test "#501 prefer_implementation: hover shows the documentation of the body in the submodule" {
    const w = try h.Workspace.init(&separate_procedures, .{ .settings = .{ .prefer_implementation = true } });
    defer w.deinit();
    try h.check(501, .fixed, expectImplementation(w, true));
}

test "#502 prefer_implementation: go to definition goes to the body in the submodule" {
    const w = try h.Workspace.init(&separate_procedures, .{ .settings = .{ .prefer_implementation = true } });
    defer w.deinit();
    try h.check(502, .fixed, expectImplementation(w, false));
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
        const docs = param[(std.mem.find(u8, param, "-----") orelse break :blk h.unmet("no documentation: {s}", .{param}))..];
        if (std.mem.find(u8, docs, "\n ") != null) break :blk h.unmet("an indented line in the documentation: {s}", .{docs});
        break :blk h.expect(std.mem.find(u8, docs, "DEMONSTRATE\nTHE BROKEN PARSING OF\nDOCSTRINGS FOR FIXED FORMAT CODE") != null, "hover of PARAM1: {s}", .{param});
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

test "hansec #203 preprocessor directives inside a continued declaration" {
    const files = [_]h.File{.{
        .name = "t.F90",
        .text =
        \\program p
        \\  implicit none
        \\  REAL &
        \\#ifdef X
        \\  , POINTER &
        \\#else
        \\  , ALLOCATABLE &
        \\#endif
        \\  :: v(:)
        \\  print *, v
        \\end program p
        \\
        ,
    }};
    const Case = struct { defs: []const @import("zfls").settings.PpDef, want: []const u8, not: []const u8 };
    const outcome: anyerror!void = blk: {
        for ([_]Case{
            .{ .defs = &.{}, .want = "ALLOCATABLE", .not = "POINTER" },
            .{ .defs = &.{.{ .name = "X", .value = "" }}, .want = "POINTER", .not = "ALLOCATABLE" },
        }) |c| {
            const w = try h.Workspace.init(&files, .{ .pp_defs = c.defs });
            defer w.deinit();
            const text = (try w.hover("t.F90", w.pos("t.F90", "print *, v", 0, 9))) orelse
                break :blk h.unmet("no hover on v (X defined: {})", .{c.defs.len > 0});
            if (std.mem.find(u8, text, c.want) == null or std.mem.find(u8, text, c.not) != null)
                break :blk h.unmet("hover of v (X defined: {}): {s}", .{ c.defs.len > 0, text });
        }
    };
    try h.checkIn(.hansec, 203, .fixed, outcome);
}

const integrate =
    \\MODULE myMOD
    \\  IMPLICIT NONE
    \\  PRIVATE
    \\  PUBLIC :: integrate
    \\  INTERFACE integrate
    \\    MODULE PROCEDURE int_2D
    \\    MODULE PROCEDURE int_3D
    \\  END INTERFACE integrate
    \\CONTAINS
    \\  SUBROUTINE int_2D(x, y)
    \\    REAL, INTENT(IN) :: x, y
    \\  END SUBROUTINE int_2D
    \\  SUBROUTINE int_3D(x, y, z)
    \\    REAL, INTENT(IN) :: x, y, z
    \\  END SUBROUTINE int_3D
    \\END MODULE myMOD
    \\PROGRAM main
    \\  USE myMOD
    \\  CALL integrate(1.0, 2.0)
    \\  CALL integrate(1.0, 2.0, 3.0)
    \\  CALL integrate(1.0, 2.0, z=3.0)
    \\END PROGRAM main
    \\
;

fn expectGenericSignatures(w: *h.Workspace) !void {
    // after the first argument both procedures take the call: the smaller
    const one = (try w.signature("m.f90", w.pos("m.f90", "integrate(1.0, 2.0)\n", 0, 10))) orelse return h.unmet("no signature help", .{});
    try h.expect(one.count == 2, "{d} signatures, not 2", .{one.count});
    try h.expect(std.mem.startsWith(u8, one.label, "int_2D"), "active signature {s}, not int_2D", .{one.label});
    // a third argument: only int_3D
    const three = (try w.signature("m.f90", w.pos("m.f90", "integrate(1.0, 2.0, 3.0)", 0, 20))) orelse return h.unmet("no signature help", .{});
    try h.expect(std.mem.startsWith(u8, three.label, "int_3D") and three.active == 2, "active {s} parameter {d}, not int_3D 2", .{ three.label, three.active });
}

test "#6 signature help shows each procedure of a generic interface, the one the arguments fit active" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text = integrate }}, .{ .settings = .{ .use_signature_help = true } });
    defer w.deinit();
    try h.check(6, .fixed, expectGenericSignatures(w));
}

fn expectSpecificDefinition(w: *h.Workspace) !void {
    const two = (try w.definition("m.f90", w.pos("m.f90", "integrate(1.0, 2.0)\n", 0, 2))) orelse return h.unmet("no definition", .{});
    try h.expect(two.line == 9, "the 2-argument call goes to line {d}, not 10 (int_2D)", .{two.line + 1});
    const three = (try w.definition("m.f90", w.pos("m.f90", "integrate(1.0, 2.0, 3.0)", 0, 2))) orelse return h.unmet("no definition", .{});
    try h.expect(three.line == 12, "the 3-argument call goes to line {d}, not 13 (int_3D)", .{three.line + 1});
    const kw = (try w.definition("m.f90", w.pos("m.f90", "integrate(1.0, 2.0, z=3.0)", 0, 2))) orelse return h.unmet("no definition", .{});
    try h.expect(kw.line == 12, "the call with z= goes to line {d}, not 13 (int_3D)", .{kw.line + 1});
}

test "hansec #135 go to definition on a call of a generic interface goes to the procedure the arguments fit" {
    const w = try h.Workspace.init(&.{.{ .name = "m.f90", .text = integrate }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 135, .fixed, expectSpecificDefinition(w));
}

/// The hover of a variable, its declaration line alone, is `want`
fn expectDecl(w: *h.Workspace, name: []const u8, p: h.Pos, want: []const u8) !void {
    const got = (try w.hover(name, p)) orelse return h.unmet("{s}:{d}:{d}: no hover, expected {s}", .{ name, p.line + 1, p.col, want });
    const fenced = try std.mem.concat(std.testing.allocator, u8, &.{ "\n", want, "\n" });
    defer std.testing.allocator.free(fenced);
    if (std.mem.find(u8, got, fenced) == null) return h.unmet("{s}:{d}:{d}: hover is not {s}: {s}", .{ name, p.line + 1, p.col, want, got });
}

const attr_stmts = [_]h.File{
    .{ .name = "a.f90", .text =
    \\module m
    \\  implicit none
    \\contains
    \\  subroutine t(v, n, w)
    \\    integer :: n
    \\    real :: v, w
    \\    dimension v(n)
    \\    optional :: w
    \\    v(1) = 0
    \\  end subroutine
    \\  subroutine caller()
    \\    real :: arr(4)
    \\    call t(arr, 4)
    \\  end subroutine
    \\  subroutine before(q)
    \\    dimension q(2)
    \\    intent(out) q
    \\    real :: q
    \\    q = 0
    \\  end subroutine
    \\end module
    \\
    },
    .{ .name = "b.f90", .text =
    \\subroutine attrs(a, b)
    \\  real :: x, y, z, a, b, c
    \\  dimension x(3), a(*)
    \\  allocatable :: y(:)
    \\  pointer :: z
    \\  intent(in) :: a
    \\  optional :: b
    \\  save x
    \\  save
    \\  save /blk/
    \\  target :: c
    \\  c = x(1) + a(1)
    \\end subroutine
    \\
    },
    .{ .name = "c.f", .text =
    \\      SUBROUTINE S
    \\      PARAMETER (PI=3.14159, KMAX=10)
    \\      DIMENSION A(10)
    \\      A(1) = PI
    \\      PRINT *, KMAX
    \\      END
    \\
    },
    // a type declaration keeps the attributes after VALUE
    .{ .name = "d.f90", .text =
    \\subroutine s(x, y)
    \\  integer, value, intent(in) :: x
    \\  real, volatile :: y
    \\  y = x
    \\end subroutine
    \\
    },
};

test "attribute statements give their attribute to the names they list (#238)" {
    const w = try h.Workspace.init(&attr_stmts, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("a.f90");
    try expectDecl(w, "a.f90", w.pos("a.f90", "v(1) = 0", 0, 0), "REAL, DIMENSION(n) :: v");
    try expectDecl(w, "a.f90", w.pos("a.f90", "w)", 0, 0), "REAL, OPTIONAL :: w");
    // the declaration after the statements
    try expectDecl(w, "a.f90", w.pos("a.f90", "q = 0", 0, 0), "REAL, DIMENSION(2), INTENT(OUT) :: q");
    for ([_][2][]const u8{
        .{ "x, y", "REAL, DIMENSION(3), SAVE :: x" },
        .{ "y, z", "REAL, ALLOCATABLE, DIMENSION(:) :: y" },
        .{ "z, a", "REAL, POINTER :: z" },
        .{ "a, b, c", "REAL, DIMENSION(*), INTENT(IN) :: a" },
        .{ "b, c", "REAL, OPTIONAL :: b" },
        .{ "c\n", "REAL, TARGET :: c" },
    }) |case| try expectDecl(w, "b.f90", w.pos("b.f90", case[0], 0, 0), case[1]);
    // implicitly typed names: the statement declares them
    try expectDecl(w, "c.f", w.pos("c.f", "PI\n", 0, 0), "REAL, PARAMETER :: PI = 3.14159");
    try expectDecl(w, "c.f", w.pos("c.f", "PI=", 0, 0), "REAL, PARAMETER :: PI = 3.14159");
    try expectDecl(w, "c.f", w.pos("c.f", "KMAX\n", 0, 0), "INTEGER, PARAMETER :: KMAX = 10");
    try expectDecl(w, "c.f", w.pos("c.f", "A(1)", 0, 0), "REAL, DIMENSION(10) :: A");
    try expectDecl(w, "c.f", w.pos("c.f", "A(10)", 0, 0), "REAL, DIMENSION(10) :: A");
    const def = (try w.definition("c.f", w.pos("c.f", "PI\n", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 1), def.line);
    try expectDecl(w, "d.f90", w.pos("d.f90", "x\n", 0, 0), "INTEGER, VALUE, INTENT(IN) :: x");
    try expectDecl(w, "d.f90", w.pos("d.f90", "y = x", 0, 0), "REAL, VOLATILE :: y");
}

test "`pass ( self )` with blanks names the passed-object argument (#243)" {
    const w = try h.Workspace.init(&.{.{ .name = "a.f90", .text =
        \\module m
        \\  implicit none
        \\  type t
        \\    integer :: v
        \\  contains
        \\    procedure, pass ( self ) :: get
        \\    procedure, pass(self) :: get2 => get
        \\    procedure, PASS( SELF ), public :: get3 => get
        \\  end type
        \\contains
        \\  integer function get(k, self)
        \\    integer, intent ( in ) :: k
        \\    class(t), intent(in) :: self
        \\    get = self%v + k
        \\  end function
        \\  subroutine use_it()
        \\    type(t) :: o
        \\    print *, o%get(1)
        \\    print *, o%get2(1)
        \\    print *, o%get3(1)
        \\  end subroutine
        \\end module
        \\
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("a.f90");
    for ([_][]const u8{ "get(1)", "get2(1)", "get3(1)" }) |call| {
        const p = w.pos("a.f90", call, 0, 0);
        try w.expectHoverContains("a.f90", p, "(k) RESULT(get)\n INTEGER, INTENT(IN) :: k");
        const hv = (try w.hover("a.f90", p)).?;
        try h.expect(std.mem.find(u8, hv, ":: self") == null, "{s}: the hover lists self: {s}", .{ call, hv });
        const sig = (try w.signature("a.f90", w.pos("a.f90", call, 0, call.len - 2))) orelse return h.unmet("{s}: no signature help", .{call});
        try h.expect(std.mem.endsWith(u8, sig.label, "(k)"), "{s}: signature {s}", .{ call, sig.label });
    }
}

const decl_hovers = [_]h.File{.{ .name = "m.f90", .text =
    \\module m
    \\  implicit none
    \\  integer, parameter :: arr(3) = [1, 2, 3]
    \\  integer, dimension(3), parameter :: crr = [1, 2, 3]
    \\  character(len=3), parameter :: names(2) = ['abc', 'def']
    \\  character(len=6), parameter :: space_str = 'a   b' // "c"
    \\  character :: s(3)[*]*10
    \\  character :: s2(3)*10
    \\  real, dimension(3) :: a, b(5)
    \\  real, dimension(3), target :: c(2,2)
    \\  integer, parameter :: d(2, 2) = reshape([1, 2, 3, 4], [2, 2])
    \\  integer, parameter :: p1 = 1, p2(2) = [1, 2], p3 = 3
    \\  character(len=*), parameter :: blanks = "x  y", &
    \\       more = 'u   v'
    \\  character(len=4), parameter :: q1 = 'a;b'; integer, parameter :: q2 = 2
    \\  character(kind=4, len=200) :: k4*100
    \\contains
    \\  subroutine old(u, v)
    \\    character*(*) u, v*8
    \\    real*8 r8b, r4*4
    \\    print *, arr
    \\  end subroutine
    \\  logical function lf()
    \\    !! doc of lf
    \\    lf = .false.
    \\  end function
    \\  function lg()
    \\    !! doc of lg
    \\    logical :: lg
    \\    lg = .false.
    \\  end function
    \\end module
    \\
}};

test "hover of a declaration shows it as written: values, strings, lengths, one DIMENSION (#237)" {
    const w = try h.Workspace.init(&decl_hovers, .{});
    defer w.deinit();
    for ([_][2][]const u8{
        .{ "arr(3)", "INTEGER, PARAMETER, DIMENSION(3) :: arr = [1, 2, 3]" },
        .{ "crr", "INTEGER, DIMENSION(3), PARAMETER :: crr = [1, 2, 3]" },
        .{ "names", "CHARACTER(len=3), PARAMETER, DIMENSION(2) :: names = ['abc', 'def']" },
        .{ "space_str", "CHARACTER(len=6), PARAMETER :: space_str = 'a   b' // \"c\"" },
        .{ "s(3)", "CHARACTER*10, DIMENSION(3), CODIMENSION[*] :: s" },
        .{ "s2", "CHARACTER*10, DIMENSION(3) :: s2" },
        .{ "a, b", "REAL, DIMENSION(3) :: a" },
        .{ "b(5)", "REAL, DIMENSION(5) :: b" },
        .{ "c(2,2)", "REAL, DIMENSION(2,2), TARGET :: c" },
        .{ "d(2, 2)", "INTEGER, PARAMETER, DIMENSION(2, 2) :: d = reshape([1, 2, 3, 4], [2, 2])" },
        .{ "p1", "INTEGER, PARAMETER :: p1 = 1" },
        .{ "p2", "INTEGER, PARAMETER, DIMENSION(2) :: p2 = [1, 2]" },
        .{ "p3", "INTEGER, PARAMETER :: p3 = 3" },
        .{ "blanks", "CHARACTER(len=*), PARAMETER :: blanks = \"x  y\"" },
        .{ "more", "CHARACTER(len=*), PARAMETER :: more = 'u   v'" },
        .{ "q1", "CHARACTER(len=4), PARAMETER :: q1 = 'a;b'" },
        .{ "q2", "INTEGER, PARAMETER :: q2 = 2" },
        .{ "k4", "CHARACTER(kind=4, LEN=100) :: k4" },
        .{ "u, v", "CHARACTER*(*) :: u" },
        .{ "v*8", "CHARACTER*8 :: v" },
        .{ "r8b", "REAL*8 :: r8b" },
        .{ "r4*4", "REAL*4 :: r4" },
    }) |case| try expectDecl(w, "m.f90", w.pos("m.f90", case[0], 0, 0), case[1]);
    // the documentation of a function with a type prefix is the function's
    const lf = (try w.hover("m.f90", w.pos("m.f90", "lf()", 0, 0))) orelse return error.NoHover;
    try h.expect(std.mem.find(u8, lf, "**Return:**") == null, "lf: {s}", .{lf});
    try h.expect(std.mem.find(u8, lf, "```\n-----\ndoc of lf") != null, "lf: {s}", .{lf});
    const lg = (try w.hover("m.f90", w.pos("m.f90", "lg()", 0, 0))) orelse return error.NoHover;
    try h.expect(std.mem.find(u8, lg, "```\n-----\ndoc of lg") != null, "lg: {s}", .{lg});
    // the named-constant inlay hint has the value too
    var found = false;
    for (try w.inlayHints("m.f90")) |hint| found = found or std.mem.find(u8, hint.label, "[1, 2, 3]") != null;
    try h.expect(found, "no inlay hint = [1, 2, 3] on the use of arr", .{});
}
