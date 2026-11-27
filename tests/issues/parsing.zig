//! Upstream issues about parsing and preprocessing.

const std = @import("std");
const h = @import("harness.zig");

test "#532 identifiers that start like BLOCK are not BLOCK constructs" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module m
        \\  implicit none
        \\
        \\contains
        \\
        \\  subroutine real_vector_to_blocked_vector(vector, block_size, blocked_vector)
        \\    real, intent(in) :: vector(:)
        \\    integer, intent(in) :: block_size
        \\    real, intent(out) :: blocked_vector(:, :)
        \\    integer :: max_block_index, bloc
        \\    integer :: vindex_initial, vindex_final
        \\
        \\    bloc = 1
        \\    max_block_index = block_size
        \\    vindex_initial = 1
        \\    vindex_final = block_size
        \\
        \\    blocked_vector(1:max_block_index, bloc) = vector(vindex_initial:vindex_final)
        \\  end subroutine real_vector_to_blocked_vector
        \\
        \\  integer function index_from_block_and_block_index()
        \\    index_from_block_and_block_index = 1
        \\  end function index_from_block_and_block_index
        \\
        \\end module m
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(532, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "BLOCK, CRITICAL and BLOCK DATA are still recognized (control for #532, #292, #264)" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\block data named_data
        \\  common /c/ x
        \\  real :: x
        \\end block data named_data
        \\
        \\subroutine s()
        \\  implicit none
        \\  integer :: i
        \\  outer: block ! a comment
        \\    integer :: inner
        \\    inner = 1
        \\  end block outer
        \\  critical
        \\    i = 1
        \\  end critical
        \\  block
        \\    integer :: other
        \\    other = 2
        \\  end block
        \\end subroutine s
        \\
        ,
    }}, .{});
    defer w.deinit();
    try w.expectNoDiagnostics("t.f90");
    // the variable declared inside the construct belongs to it
    const p = w.pos("t.f90", "inner = 1", 0, 0);
    try w.expectHoverContains("t.f90", p, "INTEGER :: inner");
}

test "#292 a label or a variable named block" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\module test_rename_block
        \\    implicit none
        \\contains
        \\
        \\    subroutine block_test01()
        \\        integer :: i
        \\        block: do i = 1, 1
        \\            write(*, *) "use label with name block : ", i
        \\        end do block
        \\    end subroutine block_test01
        \\
        \\    subroutine block_test02()
        \\        integer :: block
        \\        do block = 1, 1
        \\            write(*, *) "use index name block :", block
        \\        end do
        \\    end subroutine block_test02
        \\
        \\end module test_rename_block
        \\
        \\program driver
        \\    use test_rename_block
        \\    implicit none
        \\    call block_test01()
        \\    call block_test02()
        \\end program driver
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(292, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "#411 a semicolon in a fixed-form comment does not start code" {
    const w = try h.Workspace.init(&.{.{
        .name = "invalid_comment.f",
        .text =
        \\c ; do not treat this as code
        \\      subroutine foo
        \\      end subroutine foo
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.check(411, .fixed, w.expectNoDiagnostics("invalid_comment.f"));
}

test "#486 a function-like macro with an empty argument list" {
    const w = try h.Workspace.init(&.{
        .{ .name = "main.F90", .text =
        \\program X
        \\    use A
        \\    call B()
        \\end program
        \\
        },
        .{ .name = "a.F90", .text =
        \\#define ok() if(ie/=0) then; return; end if;
        \\
        \\module A
        \\    implicit none
        \\contains
        \\    subroutine B
        \\    integer :: ie
        \\    ie = 1
        \\    ok()
        \\    end subroutine
        \\end module
        \\
        },
    }, .{});
    defer w.deinit();
    const syms = try w.workspaceSymbols("a");
    var found = false;
    for (syms) |s| if (std.ascii.eqlIgnoreCase(s, "a")) {
        found = true;
    };
    try h.check(486, .fixed, blk: {
        if (!found) break :blk h.unmet("module A is not found among the workspace symbols", .{});
        break :blk w.expectNoDiagnostics("a.F90");
    });
}

test "token pasting, stringification and empty C comments make names (#226)" {
    const w = try h.Workspace.init(&.{.{ .name = "cat.F90", .text =
        \\#define PASTE(a,b) a##b
        \\#define STR(x) #x
        \\#define WRAP(P) P , wrap_/**/P
        \\module cat_m
        \\  implicit none
        \\  integer :: PASTE(my,var)
        \\  integer :: pre/**/fix
        \\  type :: t
        \\  contains
        \\    procedure :: WRAP(abc)
        \\  end type t
        \\contains
        \\  subroutine abc(self)
        \\    class(t) :: self
        \\    myvar = 1
        \\    prefix = 2
        \\    print *, STR(hello), "a##b", 'x/**/y'
        \\  end subroutine
        \\  subroutine wrap_abc(self)
        \\    class(t) :: self
        \\  end subroutine
        \\end module
        \\
    }}, .{ .hierarchical_symbols = true });
    defer w.deinit();
    // `hello` of `STR(hello)` is still taken for a name (#227)
    for (try w.diagnostics("cat.F90")) |d| {
        if (std.mem.find(u8, d.message, "\"hello\"") == null) return h.unmet("line {d}: {s}", .{ d.line + 1, d.message });
    }
    try w.expectHoverContains("cat.F90", w.pos("cat.F90", "myvar = 1", 0, 0), "INTEGER :: myvar");
    const syms = try w.symbolPaths("cat.F90");
    for ([_][]const u8{ "cat_m/myvar", "cat_m/prefix", "cat_m/t/wrap_abc" }) |want| {
        for (syms) |s| {
            if (std.mem.eql(u8, s, want)) break;
        } else return h.unmet("no symbol {s} among {d}", .{ want, syms.len });
    }
}

test "#236 a continued line that runs into an include directive" {
    const w = try h.Workspace.init(&.{
        .{ .name = "hellomain.F90", .text =
        \\program hello
        \\
        \\   call hello1(1)
        \\   call hello2(1)
        \\
        \\end program
        \\
        },
        .{ .name = "hellosub.F90", .text =
        \\subroutine hello1 &
        \\   (i)
        \\   integer :: i
        \\   print *, 'Hello World 1!', i
        \\end subroutine
        \\
        \\subroutine hello2 &
        \\#include "hellobody.inc"
        \\
        },
        .{ .name = "hellobody.inc", .text =
        \\   (i)
        \\   integer :: i
        \\   print *, 'Hello World 2!', i
        \\end subroutine
        \\
        },
    }, .{});
    defer w.deinit();
    // the server must survive (the report is about a crash), and still know
    // the first subroutine
    const syms = try w.documentSymbols("hellosub.F90");
    var found = false;
    for (syms) |s| if (std.mem.eql(u8, s, "hello1")) {
        found = true;
    };
    try h.check(236, .fixed, h.expect(found, "hello1 is not among the {d} symbols of hellosub.F90", .{syms.len}));
}

test "#433 an ASSOCIATE name that refers to itself" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f90",
        .text =
        \\PROGRAM main
        \\   IMPLICIT NONE
        \\   integer :: i
        \\   integer :: y(10) = [(i, i = 1, 10)]
        \\
        \\   ASSOCIATE (y => y(3))
        \\      print *,y
        \\   END ASSOCIATE
        \\END PROGRAM main
        \\
        ,
    }}, .{});
    defer w.deinit();
    // hovering must answer (it recursed without bound upstream)
    _ = try w.hover("t.f90", w.pos("t.f90", "y => y(3)", 0, 0));
    _ = try w.hover("t.f90", w.pos("t.f90", "print *,y", 0, 8));
    try h.check(433, .fixed, w.expectNoDiagnostics("t.f90"));
}

test "hansec #202 a comment inside a continued fixed-form declaration does not end it" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f",
        .text =
        \\      program t
        \\      real*8 x,y
        \\     & ,z,a ! comment
        \\     & ,d,dd
        \\      dd=4
        \\      end
        \\
        ,
    }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 202, .fixed, w.expectHoverContains("t.f", w.pos("t.f", "dd=4", 0, 0), "REAL*8"));
}

test "hansec #155 a comment inside a continued fixed-form IF keeps its THEN" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f",
        .text =
        \\      subroutine s(x, y, z)
        \\      real x, y, z
        \\      if ((x .ne. y) .and. ! c1
        \\     &    (z .eq. x)) then
        \\         x = 1
        \\      end if
        \\      end
        \\
        ,
    }}, .{});
    defer w.deinit();
    // the IF block opens, so the subroutine still contains it at `x = 1`
    const syms = try w.documentSymbols("t.f");
    try h.checkIn(.hansec, 155, .fixed, blk: {
        try w.expectNoDiagnostics("t.f");
        break :blk h.expect(syms.len > 0, "no symbols", .{});
    });
}

test "a ! inside a string continued on the next fixed-form line is no comment" {
    const w = try h.Workspace.init(&.{.{
        .name = "t.f",
        .text =
        \\      program t
        \\      character*20 msg, other
        \\      data msg /'hi there!
        \\     & yes'/
        \\      integer n
        \\      n = 1
        \\      end
        \\
        ,
    }}, .{});
    defer w.deinit();
    try w.expectHoverContains("t.f", w.pos("t.f", "n = 1", 0, 0), "INTEGER");
}

// Not reported upstream (fortls has the same bug): `SUBMODULE (anc:parent)
// child` was named after its parent submodule. The files are named so that
// the child is loaded before its parent and its ancestor module.
test "a submodule of a submodule is named after the parentheses and extends its parent" {
    const w = try h.Workspace.init(&.{
        .{ .name = "a_child.f90", .text =
        \\submodule (anc:parent) child
        \\  implicit none
        \\contains
        \\  module subroutine s(x)
        \\    integer, intent(in) :: x
        \\    print *, x + from_parent
        \\  end subroutine s
        \\  module procedure f
        \\    f = from_parent
        \\  end procedure f
        \\end submodule child
        \\
        },
        .{ .name = "b_parent.f90", .text =
        \\submodule (anc) parent
        \\  implicit none
        \\  integer :: from_parent = 1
        \\end submodule parent
        \\
        },
        .{ .name = "c_anc.f90", .text =
        \\module anc
        \\  implicit none
        \\  interface
        \\    module subroutine s(x)
        \\      integer, intent(in) :: x
        \\    end subroutine s
        \\    module integer function f()
        \\    end function f
        \\  end interface
        \\end module anc
        \\
        },
    }, .{});
    defer w.deinit();
    const syms = try w.workspaceSymbols("child");
    var named = false;
    for (syms) |s| named = named or std.mem.eql(u8, s, "child");
    try h.expect(named, "no workspace symbol 'child': {any}", .{syms});
    // a name of the parent submodule is visible in the child
    const use = w.pos("a_child.f90", "from_parent", 0, 1);
    try w.expectHoverContains("a_child.f90", use, "INTEGER :: from_parent");
    const def = (try w.definition("a_child.f90", use)) orelse return h.unmet("no definition for from_parent", .{});
    try h.expect(std.mem.endsWith(u8, def.uri, "b_parent.f90"), "definition of from_parent is in {s}", .{def.uri});
    // the interfaces of the ancestor module link to the child's procedures
    for ([_][]const u8{ "subroutine s", "function f" }) |needle| {
        const impl = (try w.implementation("c_anc.f90", w.pos("c_anc.f90", needle, 0, needle.len - 1))) orelse
            return h.unmet("no implementation for '{s}'", .{needle});
        try h.expect(std.mem.endsWith(u8, impl.uri, "a_child.f90"), "implementation of '{s}' is in {s}", .{ needle, impl.uri });
    }
    try w.expectHoverContains("a_child.f90", w.pos("a_child.f90", "procedure f", 0, 10), "FUNCTION f() RESULT(f)");
}

const dec_structures = [_]h.File{.{ .name = "s.f", .text =
    \\      SUBROUTINE SHOW
    \\      IMPLICIT NONE
    \\      STRUCTURE /DBTAG/
    \\        INTEGER*4 ID
    \\        UNION
    \\          MAP
    \\            INTEGER*4 IVAL
    \\          END MAP
    \\          MAP
    \\            REAL*4 RVAL
    \\          END MAP
    \\        END UNION
    \\        STRUCTURE /STAMP/ WHEN
    \\          INTEGER*4 SECS
    \\        END STRUCTURE
    \\      END STRUCTURE
    \\      RECORD /DBTAG/ TAG, TAGS(10)
    \\      TAG.ID = 4
    \\      TAG.RVAL = 1.5
    \\      TAGS(2).WHEN.SECS = 0
    \\      IF (TAG.ID .EQ. 4 .AND. TAG.IVAL .GT. 0) TAG.ID = 1
    \\      END
    \\
}};

fn expectStructures(w: *h.Workspace) !void {
    // a RECORD is a variable of the structure's type
    try w.expectHoverContains("s.f", w.pos("s.f", "TAG, TAGS", 0, 0), "TYPE(DBTAG)");
    // `.` separates components: go to definition on a field, also of a MAP
    // and of a nested structure
    const id = (try w.definition("s.f", w.pos("s.f", "TAG.ID = 4", 0, 4))) orelse return h.unmet("no definition of TAG.ID", .{});
    try h.expect(id.line == w.pos("s.f", "INTEGER*4 ID", 0, 0).line, "TAG.ID goes to line {d}", .{id.line});
    const rval = (try w.definition("s.f", w.pos("s.f", "TAG.RVAL", 0, 4))) orelse return h.unmet("no definition of TAG.RVAL", .{});
    try h.expect(rval.line == w.pos("s.f", "REAL*4 RVAL", 0, 0).line, "TAG.RVAL goes to line {d}", .{rval.line});
    const secs = (try w.definition("s.f", w.pos("s.f", "WHEN.SECS", 0, 5))) orelse return h.unmet("no definition of WHEN.SECS", .{});
    try h.expect(secs.line == w.pos("s.f", "INTEGER*4 SECS", 0, 0).line, "WHEN.SECS goes to line {d}", .{secs.line});
    // the fields after `TAG.`
    const items = try w.completion("s.f", w.pos("s.f", "TAG.RVAL", 0, 5));
    var has_rval = false;
    for (items) |i| if (std.ascii.eqlIgnoreCase(i, "rval")) {
        has_rval = true;
    };
    try h.expect(has_rval, "completion after TAG.R: {any}", .{items});
    // the structure parses: no diagnostics (UNION and MAP end no scope),
    // operators between dots stay operators
    try w.expectNoDiagnostics("s.f");
}

test "#171 DEC STRUCTURE, RECORD, UNION and MAP, with `.` between components" {
    const w = try h.Workspace.init(&dec_structures, .{});
    defer w.deinit();
    try h.check(171, .fixed, expectStructures(w));
}

test "Modern Fortran #571 a file of DEC structures has no diagnostics" {
    const w = try h.Workspace.init(&.{.{ .name = "db.f", .text =
        \\      Structure /DbTag/
        \\      Integer*4      Name(10)
        \\      Integer*4      Id
        \\      End Structure
        \\
        \\      Structure /DbValue/
        \\      Real*4         Value
        \\      Integer*4      Status
        \\      End Structure
        \\
    }}, .{});
    defer w.deinit();
    try h.checkIn(.modern_fortran, 571, .fixed, w.expectNoDiagnostics("db.f"));
}

fn expectDotted(w: *h.Workspace) !void {
    const d = (try w.definition("t.f90", w.pos("t.f90", "inst.member2", 0, 6))) orelse return h.unmet("no definition of inst.member2", .{});
    try h.expect(d.line == w.pos("t.f90", "integer :: member2", 0, 0).line, "inst.member2 goes to line {d}", .{d.line});
    try w.expectHoverContains("t.f90", w.pos("t.f90", "inst.member2", 0, 6), "INTEGER :: member2");
}

test "hansec #45 `.` between a derived-type variable and its component" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\program t
        \\  type mytype
        \\    integer :: member1
        \\    integer :: member2
        \\  end type
        \\  type(mytype) :: inst
        \\  inst%member1 = 1
        \\  inst.member2 = 2
        \\end program t
        \\
    }}, .{});
    defer w.deinit();
    try h.checkIn(.hansec, 45, .fixed, expectDotted(w));
}

const cuda = [_]h.File{
    .{ .name = "kern.cuf", .text =
    \\module kern
    \\  use cudafor
    \\  implicit none
    \\contains
    \\  attributes(global) subroutine saxpy(n, a, x, y)
    \\    integer, value :: n
    \\    real, value :: a
    \\    real, device :: x(n), y(n)
    \\    integer :: i
    \\    i = blockDim%x * (blockIdx%x - 1) + threadIdx%x
    \\    if (i <= n) y(i) = a * x(i) + y(i)
    \\  end subroutine saxpy
    \\  attributes(device) real function twice(v)
    \\    real, value :: v
    \\    twice = 2 * v
    \\  end function twice
    \\end module kern
    \\
    },
    .{ .name = "main.cuf", .text =
    \\program main
    \\  use kern
    \\  implicit none
    \\  real, device, allocatable :: xd(:), yd(:)
    \\  allocate(xd(10), yd(10))
    \\  call saxpy<<<1, 10>>>(10, 2.0, xd, yd)
    \\end program main
    \\
    },
};

fn expectCuda(w: *h.Workspace) !void {
    // kernels and device procedures are procedures of the module, in .cuf
    // files
    const d = (try w.definition("main.cuf", w.pos("main.cuf", "saxpy<<<", 0, 1))) orelse return h.unmet("no definition of saxpy", .{});
    try h.expect(std.mem.endsWith(u8, d.uri, "kern.cuf") and d.line == w.pos("kern.cuf", "subroutine saxpy", 0, 0).line, "saxpy goes to {s}:{d}", .{ d.uri, d.line });
    try w.expectHoverContains("kern.cuf", w.pos("kern.cuf", "twice = 2", 0, 0), "twice");
    // signature help past the launch configuration
    const sig = (try w.signature("main.cuf", w.pos("main.cuf", "2.0, xd", 0, 5))) orelse return h.unmet("no signature help in the kernel launch", .{});
    try h.expect(std.mem.find(u8, sig.label, "saxpy") != null and sig.active == 2, "signature {s}, parameter {d}", .{ sig.label, sig.active });
    // cudafor is known, ATTRIBUTES is no name
    try w.expectNoDiagnostics("kern.cuf");
    try w.expectNoDiagnostics("main.cuf");
}

test "CUDA Fortran: kernels, the launch syntax and .cuf files" {
    const w = try h.Workspace.init(&cuda, .{});
    defer w.deinit();
    try expectCuda(w);
}

// The form the editor says a document has (its language)

const forms = [_]h.File{
    // fixed-form source with a free-form extension
    .{ .name = "legacy.f90", .text =
    \\C     a fixed-form file with a free-form extension
    \\      subroutine s(aaa)
    \\      integer aaa,
    \\     &        bbb
    \\      bbb = aaa
    \\      end
    \\
    },
    // free-form source with a fixed-form extension, whose text does not
    // tell: as fixed form, the line of the call is a comment
    .{ .name = "x.f", .text =
    \\      module m
    \\      contains
    \\      subroutine callee()
    \\      end subroutine
    \\      subroutine caller()
    \\call callee()
    \\      end subroutine
    \\      end module
    \\
    },
};

fn expectFixedByLanguage(w: *h.Workspace) !void {
    try w.open("legacy.f90", "FortranFixedForm");
    try h.expect(try w.isFixed("legacy.f90"), "legacy.f90 opened as FortranFixedForm is read as free form", .{});
    try w.expectHoverContains("legacy.f90", w.pos("legacy.f90", "bbb = aaa", 0, 0), "INTEGER :: bbb");
    // after a change and a save too
    const changed =
        \\C     a fixed-form file with a free-form extension
        \\      subroutine s(aaa)
        \\      integer aaa,
        \\     &        bbb,
        \\     &        ccc
        \\      ccc = aaa
        \\      end
        \\
    ;
    try w.replaceText("legacy.f90", changed);
    try h.expect(try w.isFixed("legacy.f90"), "legacy.f90 is free form after a change", .{});
    const hover = (try w.hover("legacy.f90", .{ .line = 5, .col = 6 })) orelse return h.unmet("no hover after the change", .{});
    try h.expect(std.mem.find(u8, hover, "INTEGER :: ccc") != null, "after the change, hover gives {s}", .{hover});
    // closed, it is what its name says again
    try w.close("legacy.f90");
    try h.expect(!try w.isFixed("legacy.f90"), "legacy.f90 stays fixed form when closed", .{});
}

fn expectFreeByLanguage(w: *h.Workspace) !void {
    const call = w.pos("x.f", "callee()", 1, 0);
    // not open: by its text, fixed form
    try h.expect(try w.isFixed("x.f"), "x.f is indexed as free form", .{});
    try w.open("x.f", "FortranFreeForm");
    try h.expect(!try w.isFixed("x.f"), "x.f opened as FortranFreeForm is read as fixed form", .{});
    const def = (try w.definition("x.f", call)) orelse return h.unmet("the call in x.f is not read (a comment in fixed form)", .{});
    try h.expect(def.line == 2, "callee is defined in line {d}", .{def.line});
}

test "Modern Fortran #200 a document opened as FortranFixedForm is read as fixed form, whatever its extension" {
    const w = try h.Workspace.init(&forms, .{});
    defer w.deinit();
    try h.checkIn(.modern_fortran, 200, .fixed, expectFixedByLanguage(w));
}

test "Modern Fortran #200 a document opened as FortranFreeForm is read as free form, whatever its extension" {
    const w = try h.Workspace.init(&forms, .{});
    defer w.deinit();
    try h.checkIn(.modern_fortran, 200, .fixed, expectFreeByLanguage(w));
}

test "a document opened as fortran (other editors) has the form of its name and text" {
    const w = try h.Workspace.init(&forms, .{});
    defer w.deinit();
    try w.open("legacy.f90", "fortran");
    try w.open("x.f", "fortran90");
    try std.testing.expect(!try w.isFixed("legacy.f90"));
    try std.testing.expect(try w.isFixed("x.f"));
    try std.testing.expect((try w.definition("x.f", w.pos("x.f", "callee()", 1, 0))) == null);
}

// `\x0c` is a form feed, a page break of old sources: compilers read it as
// white space
const form_feed = [_]h.File{
    .{ .name = "a.f90", .text = "program p\n  implicit none\n  integer :: abc\n\x0c  integer :: def\n  integer \x0c:: ghi\n\x0c\n  abc = 1\n  def = abc + ghi\nend program\n" },
    .{ .name = "b.f", .text = "      program q\n      implicit none\n\x0c     integer zz\n      zz = 1\n      end\n" },
    .{ .name = "c.f90", .text = "module m\n\x0c  integer :: mv\nend module m\n" },
};

fn expectFormFeed(w: *h.Workspace) !void {
    try w.expectNoDiagnostics("a.f90");
    try w.expectNoDiagnostics("b.f");
    try w.expectHoverContains("a.f90", w.pos("a.f90", "def = abc", 0, 0), "INTEGER :: def");
    try w.expectHoverContains("a.f90", w.pos("a.f90", "ghi\nend", 0, 0), "INTEGER :: ghi");
    try w.expectHoverContains("b.f", w.pos("b.f", "zz = 1", 0, 0), "INTEGER :: zz");
    // the outline lists module variables
    const symbols = try w.symbolPaths("c.f90");
    for (symbols) |sym| {
        if (std.mem.eql(u8, sym, "m/mv")) break;
    } else return h.unmet("mv is not in the outline: {any}", .{symbols});
}

test "fortls #443 a form feed at the start of a line" {
    const w = try h.Workspace.init(&form_feed, .{ .hierarchical_symbols = true });
    defer w.deinit();
    try h.check(443, .fixed, expectFormFeed(w));
}

const quotes = [_]h.File{.{ .name = "a.f90", .text =
    \\module m
    \\  implicit none
    \\  character(len=*), parameter :: msg = "it's", tag = 'x'
    \\  character(len=5) :: m2 = "it's", t2 = "Bob's", u2 = 'z'
    \\contains
    \\  subroutine foo(a, b, c)
    \\    character(len=*) :: a, b
    \\    integer :: c
    \\  end subroutine
    \\  subroutine caller()
    \\    call foo("it's", "Bob's", 1)
    \\    call foo("its", "Bobs", 1)
    \\    call foo('it''s', 'Bob''s', 1)
    \\    call foo("it""s", "Bob's", 1)
    \\    call foo('it''s', "Bob's", 1)
    \\    call foo("it's", 'Bob''s', 1)
    \\  end subroutine
    \\end module
    \\
}};

fn expectQuotes(w: *h.Workspace) !void {
    const syms = try w.symbolPaths("a.f90");
    for ([_][]const u8{ "m/msg", "m/tag", "m/m2", "m/t2", "m/u2" }) |name| {
        var found = false;
        for (syms) |s| found = found or std.mem.eql(u8, s, name);
        try h.expect(found, "{s} is not in the symbols", .{name});
    }
    try w.expectHoverContains("a.f90", w.pos("a.f90", "tag", 0, 0), "CHARACTER(len=*), PARAMETER :: tag = 'x'");
    for (0..6) |i| {
        const p = w.pos("a.f90", ", 1)", i, 2);
        const sig = (try w.signature("a.f90", p)) orelse return h.unmet("line {d}: no signature help", .{p.line + 1});
        try h.expect(sig.active == 2, "line {d}: active parameter {d}, not 2", .{ p.line + 1, sig.active });
    }
    try w.expectNoDiagnostics("a.f90");
}

test "a string holding the other quote character ends where its own quote does (#231)" {
    const w = try h.Workspace.init(&quotes, .{ .hierarchical_symbols = true });
    defer w.deinit();
    try expectQuotes(w);
}

test "an undeclared name after strings holding both quote characters is reported (#231)" {
    const w = try h.Workspace.init(&.{.{ .name = "p.f90", .text =
        \\program p
        \\  implicit none
        \\  print *, 'say "hi"', "it's", x
        \\end program p
        \\
    }}, .{});
    defer w.deinit();
    var found = false;
    for (try w.diagnostics("p.f90")) |d| found = found or (d.line == 2 and std.mem.find(u8, d.message, "x") != null);
    try std.testing.expect(found);
}

test "a file saved with a byte order mark defines what its first line declares (#962)" {
    const w = try h.Workspace.init(&.{
        .{ .name = "m.f90", .text = "\xEF\xBB\xBFmodule bom_mod\n  implicit none\n  integer :: bval\nend module bom_mod\n" },
        .{ .name = "p.f90", .text = "program p\n  use bom_mod\n  implicit none\n  print *, bval\nend program p\n" },
    }, .{});
    defer w.deinit();
    try w.open("p.f90", "fortran");
    try w.expectHoverContains("p.f90", w.pos("p.f90", "bval", 0, 0), "INTEGER :: bval");
}

test "MODULE PROCEDURE and IMPORT lists with a comment after them (#963)" {
    const w = try h.Workspace.init(&.{.{ .name = "g.f90", .text =
        \\module g
        \\  implicit none
        \\  interface f
        \\    module procedure f_r4, f_r8 ! kinds
        \\  end interface
        \\contains
        \\  subroutine f_r4(x)
        \\    real(4), intent(in) :: x
        \\  end subroutine
        \\  subroutine f_r8(x)
        \\    real(8), intent(in) :: x
        \\  end subroutine
        \\end module g
        \\
    }}, .{});
    defer w.deinit();
    try w.open("g.f90", "fortran");
    const d = (try w.definition("g.f90", w.pos("g.f90", "f_r8 !", 0, 0))) orelse return error.NoDefinition;
    try std.testing.expectEqual(@as(i64, 9), d.line);
}

test "EXTENDS with blanks, and bindings with PASS, NON_OVERRIDABLE (#964)" {
    const w = try h.Workspace.init(&.{.{ .name = "t.f90", .text =
        \\module t
        \\  implicit none
        \\  type :: base
        \\    integer :: bv
        \\  contains
        \\    procedure, pass, private :: hidden => base_hidden
        \\    procedure, non_overridable, public :: shown => base_hidden
        \\  end type
        \\  type, extends ( base ) :: child
        \\  end type
        \\contains
        \\  subroutine base_hidden(self)
        \\    class(base), intent(in) :: self
        \\  end subroutine
        \\  subroutine use_it(c)
        \\    type(child), intent(in) :: c
        \\    print *, c%bv
        \\    call c%hidden()
        \\    call c%shown()
        \\  end subroutine
        \\end module t
        \\
    }}, .{});
    defer w.deinit();
    try w.open("t.f90", "fortran");
    // the parent's component through the child
    try w.expectHoverContains("t.f90", w.pos("t.f90", "bv\n", 1, 0), "INTEGER :: bv");
    // the bindings after PASS and NON_OVERRIDABLE
    for ([_][]const u8{ "hidden()", "shown()" }) |call| {
        const d = (try w.definition("t.f90", w.pos("t.f90", call, 0, 0))) orelse return h.unmet("no definition of {s}", .{call});
        try h.expect(d.line == 5 or d.line == 6 or d.line == 11, "{s} goes to line {d}", .{ call, d.line + 1 });
    }
}
